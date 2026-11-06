-- ravensight/core.lua: the SDK's state machine, with no LÖVE calls in it.
--
-- Everything the outside world provides is injected through `deps`, so the
-- whole of session handling, batching, backoff, the kill switch, opt-out and
-- quit sequencing runs under plain LuaJIT in the tests with a fake clock and
-- a fake network. ravensight/init.lua wires it to LÖVE.
--
-- It mirrors the Godot SDK (Ravensight.gd) behaviour for behaviour, so every
-- promise in the docs holds for a LÖVE game too:
--
--   * a random per-install device id, 32 hex characters, a dash and the
--     lowercased OS name, never derived from hardware or an account
--   * GET /api/v1/settings once at start; the kill switch wins when off
--   * POST /api/v1/session, then POST /api/v1/track/batch, 50 events at most,
--     sent every flushInterval seconds (2 by default) or as soon as 50 wait
--   * backoff from 10 seconds, doubling to a 5 minute cap, Retry-After obeyed
--   * the response table of the delivery contract: an indexed 400 drops one
--     event, batch_too_large halves, 413 and 415 resend smaller or plain
--   * the player's opt-out is saved and honoured before anything is sent
--
-- The delivery contract (docs: DELIVERY_CONTRACT.md on the server): unsent
-- events live in a saved queue, one file per ingest key, written atomically
-- whenever it changes, with the origin of the session each event was queued
-- under; bodies of 1,024 bytes or more go gzip compressed; a session that
-- gives a signing secret has every batch signed. consent = "opt_in" sends
-- nothing at all until the player says yes; a refused key (401 or 403) ends
-- the run instead of retrying; every event carries an rs_event_id so a
-- resend can be recognised.
--
-- MIT licensed, part of ravensight-love.

local json = require(((...):gsub('core$', 'json')))

local Config = require(((...):gsub('core$', 'config')))
local Errors = require(((...):gsub('core$', 'errors')))
local Typed = require(((...):gsub('core$', 'typed')))
local Hmac = require(((...):gsub('core$', 'hmac')))

local Core = {}
Core.__index = Core

Core.VERSION = '0.6.0'
Core.MAX_BATCH_SIZE = 50
Core.DEFAULT_RETRY_SECONDS = 10
Core.MAX_BACKOFF_SECONDS = 300
Core.QUIT_FLUSH_TIMEOUT_SECONDS = 1.5
Core.DEFAULT_FLUSH_INTERVAL_SECONDS = 2
Core.DEFAULT_MAX_QUEUE_SIZE = 500
Core.MIN_RETRY_SECONDS = 0.5
--- A backoff wait is multiplied by a random factor of at least this and
--- below 1. Retry-After is never spread.
Core.JITTER_MIN_FACTOR = 0.5
--- A batch 401 opens a new session this many times in a row, then waits.
Core.MAX_REAUTH_ATTEMPTS = 1
--- The saved queue: format version, its cap and the oldest event kept.
Core.QUEUE_FORMAT_VERSION = 2
Core.QUEUE_MAX_EVENTS = 500
Core.QUEUE_MAX_AGE_MS = 89 * 86400 * 1000
--- Request bodies of at least this many bytes are sent gzip compressed.
Core.GZIP_MIN_BYTES = 1024
--- Device fields on the session: each at most this many characters.
Core.DEVICE_FIELD_MAX_CHARS = 128
--- The largest event the API accepts, measured as the server measures it:
--- the JSON of the event's data. Bigger events are dropped before queueing.
Core.MAX_EVENT_BYTES = 8192

--- The categories the feedback endpoint accepts. Anything else is refused
--- before it is sent.
Core.FEEDBACK_CATEGORIES = {
  bug = true, suggestion = true, complaint = true, praise = true, playtest = true, other = true,
}

Core.DEVICE_ID_FILE = 'ravensight_device_id'
Core.OPTOUT_FILE = 'ravensight_optout'
--- The queue file of 0.5 and earlier: a plain list of events, read once
--- and removed.
Core.LEGACY_QUEUE_FILE = 'ravensight_queue.json'
Core.QUEUE_FILE = Core.LEGACY_QUEUE_FILE
--- Present once this install has sent its attribution event.
Core.ATTRIBUTION_FILE = 'ravensight_attribution'
--- Written only with consent = "opt_in", once the player has said yes.
Core.OPTIN_FILE = 'ravensight_optin'

Core.CONSENT_OPT_OUT = 'opt_out'
Core.CONSENT_OPT_IN = 'opt_in'

--- "opt_in" or "opt_out" from an option value; anything else is opt_out.
function Core.normalizeConsent(value)
  if value == Core.CONSENT_OPT_IN then return Core.CONSENT_OPT_IN end
  return Core.CONSENT_OPT_OUT
end

--- The player's saved choice for a consent mode, read from storage: true
--- when tracking may run. opt_out: on unless an opt-out was saved. opt_in:
--- off unless an opt-in was saved.
function Core.savedChoice(storage, consent)
  if consent == Core.CONSENT_OPT_IN then return storage.read(Core.OPTIN_FILE) ~= nil end
  return storage.read(Core.OPTOUT_FILE) == nil
end

--- Saves the player's choice in the file the consent mode reads.
function Core.saveChoice(storage, consent, enabled)
  if consent == Core.CONSENT_OPT_IN then
    if enabled then storage.write(Core.OPTIN_FILE, '1') else storage.remove(Core.OPTIN_FILE) end
  else
    if enabled then storage.remove(Core.OPTOUT_FILE) else storage.write(Core.OPTOUT_FILE, '1') end
  end
end

--- A unix millisecond clock from a whole-second wall clock and a monotonic
--- timer, because os.time has no fraction. The two are lined up on first use
--- and again whenever they disagree by more than two seconds (the player set
--- the clock, or the machine slept). It can read up to a second early, but it
--- only moves forward between those, which is what keeps events in order.
--- @param time function unix seconds
--- @param now function monotonic seconds
--- @return function unix milliseconds, a whole number
function Core.wallClockMs(time, now)
  local wallAnchor, monotonicAnchor
  return function()
    local wall, monotonic = time(), now()
    if not wallAnchor or math.abs(wallAnchor + (monotonic - monotonicAnchor) - wall) > 2 then
      wallAnchor, monotonicAnchor = wall, monotonic
    end
    return math.floor((wallAnchor + (monotonic - monotonicAnchor)) * 1000)
  end
end

--- Builds an event id from its parts: the first 16 characters of the device
--- id, the start time in hex, a per-launch nonce and a counter.
function Core.eventId(deviceId, startTime, nonce, counter)
  return string.format('%s-%x-%s-%d', tostring(deviceId or ''):sub(1, 16), math.floor(tonumber(startTime) or 0), nonce, counter)
end

--- An error event's text fields and the length within which each counts
--- one byte a character toward the 8 KB ceiling (delivery contract,
--- section 6, which defers to the errors contract for the cuts).
Core.ERROR_TEXT_CAPS = { rs_message = 200, rs_stack = 2000, rs_trail = 1500 }

--- The serialized size of an event's data, as the server measures it: its
--- JSON in bytes, except that an error event's rs_message, rs_stack and
--- rs_trail, each within its cap, count one byte a character, so escaping
--- never pushes an allowed text over the limit.
function Core.eventBytes(data)
  local size = #json.encode(data)
  if type(data) ~= 'table' or data.rs_kind ~= 'error' then return size end
  for key, cap in pairs(Core.ERROR_TEXT_CAPS) do
    local value = data[key]
    if type(value) == 'string' then
      local units = Typed.utf16Length(value)
      if units <= cap then size = size - (#json.encode(value) - units) end
    end
  end
  return size
end

--- 64-bit FNV-1a of a string's bytes as 16 lowercase hex characters, worked
--- in two 32-bit halves so no step loses precision in a double.
function Core.fnv1a64(text)
  local hi, lo = 0xcbf29ce4, 0x84222325
  for i = 1, #text do
    local low = lo % 256
    lo = lo - low + bit.bxor(low, text:byte(i))
    local product = lo * 0x1b3
    hi = (hi * 0x1b3 + lo * 0x100 + math.floor(product / 4294967296)) % 4294967296
    lo = product % 4294967296
  end
  return string.format('%08x%08x', hi, lo)
end

--- This key's queue file, named by the hash of the key. It separates keys;
--- it is no secret.
function Core.queueFile(ingestKey)
  return 'ravensight/queue-' .. Core.fnv1a64(ingestKey or '') .. '.json'
end

local EVENTS = {
  config_ready = true, session_ready = true, session_failed = true, tracking_disabled = true,
  events_flushed = true, flush_failed = true, feedback_submitted = true,
  feedback_failed = true, event_tracked = true,
}

local function noop() end

--- True when `id` has the shape the SDK generates. Anything else found on
--- disk is replaced with a fresh random id.
local DEVICE_ID_PATTERN = '^' .. string.rep('[0-9a-f]', 32) .. '%-[a-z0-9]+$'

function Core.is_random_device_id(id)
  return type(id) == 'string' and id:match(DEVICE_ID_PATTERN) ~= nil
end

--- deps:
---   apiUrl, ingestKey, gameVersion  configuration (strings)
---   maxQueueSize                    unsent events kept, oldest dropped first
---   flushInterval                   seconds an event may wait before a flush
---   send(req, callback)             req = {method, url, headers, body};
---                                   callback(status, body, headers) where
---                                   status is 0 for a network failure and
---                                   headers is a table of lowercased names
---   now()                           seconds, monotonic, for timers
---   time()                          unix seconds, for expiry
---   timeMs()                        unix milliseconds, for event timestamps,
---                                   default Core.wallClockMs(time, now)
---   storage                         {read(name), write(name, text), remove(name)}
---   randomHex(bytes)                cryptographically random lowercase hex
---   platform, osName                e.g. "macOS" and "macos"
---   log(level, message)             "info", "warn" or "error"
---   playtest                        {token, run_id, job_id, persona, tier} or nil
---   consent                         "opt_out" (default) or "opt_in"
---   distribution                    optional string sent on the session
---   random()                        0 <= x < 1, for backoff jitter,
---                                   default math.random
---   gzip(text)                      the gzip stream of text, or nil when the
---                                   platform has none (bodies go plain)
---   sha256(bytes)                   the raw SHA-256 digest, default a pure
---                                   Lua one (ravensight/hmac.lua)
---   device                          {model, osVersion, gpu} as the engine
---                                   reports them, any may be missing
function Core.new(deps)
  assert(type(deps) == 'table', 'ravensight: core needs its dependencies')
  local self = setmetatable({}, Core)
  self.apiUrl = Core.normalizeApiUrl(deps.apiUrl)
  self.ingestKey = deps.ingestKey or ''
  self.gameVersion = deps.gameVersion or '1.0.0'
  self.maxQueueSize = deps.maxQueueSize or Core.DEFAULT_MAX_QUEUE_SIZE
  self.flushInterval = deps.flushInterval or Core.DEFAULT_FLUSH_INTERVAL_SECONDS
  self.send = assert(deps.send, 'ravensight: core needs send')
  self.now = deps.now or os.clock
  self.time = deps.time or os.time
  self.timeMs = deps.timeMs or Core.wallClockMs(self.time, self.now)
  self.storage = deps.storage or { read = noop, write = noop, remove = noop }
  self.randomHex = assert(deps.randomHex, 'ravensight: core needs randomHex')
  self.platform = deps.platform or 'unknown'
  self.osName = deps.osName or 'unknown'
  self.log = deps.log or noop
  self.random = deps.random or math.random
  self.gzip = deps.gzip
  self.sha256 = deps.sha256 or Hmac.sha256
  self.device = Core.deviceFields(deps.device)
  self.consent = Core.normalizeConsent(deps.consent)
  if type(deps.distribution) == 'string' and deps.distribution ~= '' then
    self.distribution = deps.distribution
  end

  self.listeners = {}
  self.deviceId = ''
  self.sessionToken = ''
  self.sessionExpiresAt = 0
  self.sessionPending = false
  self.sessionGeneration = 0
  self.configGeneration = 0
  self.configPending = false
  self.configDocument = nil
  self.configScope = nil
  self.trackingEnabled = true
  self.serverTrackingEnabled = true
  self.playerOptedOut = false
  self.pending = {}
  self.firstQueuedAt = nil
  self.flushInProgress = false
  self.queueGeneration = 0
  self.splitBatchSize = 0
  self.backoff = Core.DEFAULT_RETRY_SECONDS
  self.retryAt = nil
  self.quitting = false
  self.quitDeadline = nil
  self.quitReady = false
  self.started = false
  self.identityLoaded = false
  self.keyRefused = false
  self.startTime = nil
  self.eventNonce = nil
  self.eventCounter = 0
  self.warnedTooLarge = false
  self.inflightSize = 0
  -- The game's error capture switches, from the session (and settings)
  -- answer's errorCapture. Absent means capture on and trail off.
  self.errorCaptureEnabled = true
  self.errorTrailEnabled = false
  -- True once a session answer has said which switches hold.
  self.sessionAnswered = false
  -- The open session's origin as received, its signing secret (memory
  -- only) and the clock correction for signatures.
  self.sessionOrigin = nil
  self.signingSecret = nil
  self.clockOffset = 0
  self.reauthAttempts = 0
  self.retryFromServer = false
  self.sendPlain = false
  self.queueDirty = false
  self.queueLoaded = false
  self.deliveryStats = { dropped_overflow = 0, dropped_too_old = 0, dropped_refused = 0 }
  self.exposed = {}

  self.playtestToken = ''
  self.playtestRunId = ''
  self.playtestTags = nil
  self.playtestBlocked = false
  if deps.playtest and deps.playtest.token and deps.playtest.token ~= '' then
    self:setPlaytestContext(deps.playtest)
  end
  return self
end

--- The API origin with any trailing slashes and a trailing /api/v1 taken
--- off, so "https://api.ravensight.io", ".../" and ".../api/v1" all work.
function Core.normalizeApiUrl(url)
  local base = tostring(url or ''):gsub('/+$', '')
  base = base:gsub('/api/v1$', '')
  return base
end

--- Subscribe to an SDK event. Returns a function that unsubscribes.
function Core:on(name, fn)
  assert(EVENTS[name], 'ravensight: unknown event "' .. tostring(name) .. '"')
  self.listeners[name] = self.listeners[name] or {}
  table.insert(self.listeners[name], fn)
  return function()
    for i, f in ipairs(self.listeners[name]) do
      if f == fn then table.remove(self.listeners[name], i) return end
    end
  end
end

function Core:emit(name, ...)
  for _, fn in ipairs(self.listeners[name] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then self.log('error', 'a ' .. name .. ' listener failed: ' .. tostring(err)) end
  end
end

-- --------------------------------------------------------------- lifecycle

--- Loads the identity, the opt-out flag and any saved queue, then checks
--- the kill switch. Call once.
function Core:start()
  if self.started then return end
  self.started = true
  self.startTime = self.time()
  if self.playtestToken == '' then
    self.playerOptedOut = not Core.savedChoice(self.storage, self.consent)
    self.trackingEnabled = not self.playerOptedOut
    -- With opt_in and no yes yet, not even the device id is created.
    if not self.playerOptedOut then self:loadIdentity() end
  end
  if self.playerOptedOut then
    -- Nothing leaves the device, not even the settings check.
    if self.consent == Core.CONSENT_OPT_IN then
      self.log('info', 'waiting for the player to opt in (consent = "opt_in")')
    else
      self.log('info', 'tracking disabled by player opt-out')
    end
    self:emit('tracking_disabled', 'player')
  else
    self:checkServerSettings()
  end
end

--- The saved device id (made on first use) and any saved queue.
function Core:loadIdentity()
  if self.identityLoaded or self.playtestToken ~= '' then return end
  self.identityLoaded = true
  self.deviceId = self:loadOrCreateDeviceId()
  self:loadSavedQueue()
end

function Core:loadOrCreateDeviceId()
  local saved = self.storage.read(Core.DEVICE_ID_FILE)
  if saved then
    saved = saved:match('^%s*(.-)%s*$')
    if Core.is_random_device_id(saved) then return saved end
  end
  local id = self:generateDeviceId()
  self.storage.write(Core.DEVICE_ID_FILE, id)
  return id
end

function Core:generateDeviceId()
  return self.randomHex(16) .. '-' .. self.osName
end

--- Drives timers: the retry wait, the flush interval and the quit deadline.
--- Call every frame. The clock is now(), so dt is not needed.
function Core:update()
  local t = self.now()
  if self.retryAt and t >= self.retryAt then
    self.retryAt = nil
    self.retryFromServer = false
    if self.trackingEnabled then
      if not self:isSessionValid() then self:startSession() else self:flushPending() end
    end
  end
  -- The batching timer. A running retry wait owns the next send instead.
  if not self.retryAt and self.firstQueuedAt and t - self.firstQueuedAt >= self.flushInterval then
    self:flushPending()
  end
  if self.quitting and self.quitDeadline and t >= self.quitDeadline then
    self:finishQuit()
  end
  -- Events tracked this frame are written once, at the end of it.
  if self.queueDirty then self:saveQueue() end
end

-- ---------------------------------------------------------------- playtest

--- Switches into playtest mode: a throwaway device id that is never saved,
--- the playtest header on the session, and synthetic tags on every event.
function Core:setPlaytestContext(ctx)
  local token, runId = tostring(ctx.token or ''), tostring(ctx.run_id or '')
  if token == '' or runId == '' then
    self.log('warn', 'setPlaytestContext() needs both token and run_id')
    return
  end
  self.playtestToken = token
  self.playtestRunId = runId
  self.deviceId = 'pt-' .. runId
  self.playtestBlocked = false
  -- A playtest run ignores the player's opt-out; the flag on disk stays.
  if self.playerOptedOut then
    self.playerOptedOut = false
    self.trackingEnabled = self.serverTrackingEnabled
  end
  self:resetSessionScope()
  self.playtestTags = {
    synthetic = true,
    persona = tostring(ctx.persona or ''),
    pt_job = tostring(ctx.job_id or ''),
    pt_run = runId,
    pt_source = 'sdk',
    pt_tier = tostring(ctx.tier or 'T2_driven_build'),
  }
  if self.sessionToken ~= '' or self.sessionPending then
    self.sessionToken = ''
    self.sessionExpiresAt = 0
    self.sessionPending = false
    self:startSession()
  end
end

-- ------------------------------------------------------------- kill switch

function Core:checkServerSettings()
  if self.keyRefused then return end
  self.settingsPending = true
  self.send({
    method = 'GET',
    url = self.apiUrl .. '/api/v1/settings',
    headers = { ['X-API-Key'] = self.ingestKey },
  }, function(status, body)
    self.settingsPending = false
    if self.keyRefused then return end
    if status == 200 then
      local parsed = json.decode(body or '')
      if type(parsed) == 'table' and parsed.trackingEnabled ~= nil then
        self.serverTrackingEnabled = parsed.trackingEnabled == true
      end
      self:readErrorCapture(parsed)
    elseif status == 403 and Core.errorOf(body) == 'tracking_disabled' then
      self.serverTrackingEnabled = false
    elseif status == 401 or status == 403 then
      self:onKeyRefused(status, body)
      return
    else
      self.log('warn', 'could not fetch settings (HTTP ' .. tostring(status) .. '); assuming tracking enabled')
    end
    self:afterSettingsChecked()
  end)
end

function Core:afterSettingsChecked()
  if self.keyRefused then return end
  self.trackingEnabled = self.serverTrackingEnabled and not self.playerOptedOut
  if not self.serverTrackingEnabled then
    self.log('info', 'tracking disabled by server kill switch')
    self:clearQueue()
    self:emit('tracking_disabled', 'server')
  elseif self.trackingEnabled then
    self:track('game_started', {})
  end
end

-- ----------------------------------------------------------------- session

function Core:isSessionValid()
  return self.sessionToken ~= '' and self.time() < self.sessionExpiresAt
end

function Core:startSession()
  if self.playtestBlocked or not self.trackingEnabled or self.sessionPending then return end
  self.sessionPending = true
  self.sessionGeneration = self.sessionGeneration + 1
  local generation = self.sessionGeneration

  local headers = { ['Content-Type'] = 'application/json', ['X-API-Key'] = self.ingestKey }
  local platform = self.platform
  if self.playtestToken ~= '' then
    headers['X-Ravensight-Playtest'] = self.playtestToken
    platform = 'ravensight-playtest'
  end
  local body = { deviceId = self.deviceId, gameVersion = self.gameVersion, platform = platform }
  if self.distribution then body.distribution = self.distribution end
  if next(self.device) then body.device = self.device end
  body.sdk = 'love/' .. Core.VERSION
  self.send({
    method = 'POST',
    url = self.apiUrl .. '/api/v1/session',
    headers = headers,
    body = json.encode(body),
  }, function(status, body, responseHeaders)
    self:onSessionResponse(status, body, responseHeaders, generation)
  end)
end

local function extractError(body, fallback)
  local parsed = json.decode(body or '')
  if type(parsed) == 'table' and parsed.error ~= nil then return tostring(parsed.error) end
  return fallback
end

--- Reads errorCapture { enabled, trail } from a session or settings answer.
--- An answer without it leaves the current switches as they are.
function Core:readErrorCapture(parsed)
  local switches = type(parsed) == 'table' and parsed.errorCapture
  if type(switches) ~= 'table' then return end
  self.errorCaptureEnabled = switches.enabled ~= false
  self.errorTrailEnabled = switches.trail == true
end

--- True while automatic error capture may queue anything: tracking is on and
--- the game's switch is not off.
function Core:errorCaptureAllowed()
  return self.trackingEnabled and self.errorCaptureEnabled and not self.keyRefused
end

--- The `error` field of a JSON answer, or '' when there is none.
function Core.errorOf(body)
  return extractError(body, '')
end

local function retryAfter(headers)
  local value = headers and headers['retry-after']
  local seconds = value and tonumber((tostring(value):match('^%s*(%d+)%s*$')))
  return seconds or -1
end

function Core:onSessionResponse(status, body, headers, generation)
  -- A newer attempt has started since this one went out: ignore it.
  if generation ~= self.sessionGeneration then return end
  self.sessionPending = false

  if status == 201 then
    local parsed = json.decode(body or '')
    if type(parsed) == 'table' and parsed.token then
      self.sessionToken = tostring(parsed.token)
      self.sessionExpiresAt = self.time() + (tonumber(parsed.expiresIn) or 86400)
      self:readErrorCapture(parsed)
      self.sessionAnswered = true
      self:adoptSessionExtras(parsed)
      self.backoff = Core.DEFAULT_RETRY_SECONDS
      self.log('info', 'session ready')
      self:emit('session_ready')
      self:flushPending()
      self:fetchConfig()
    else
      self.log('error', 'malformed session response')
      self:emit('session_failed', 'malformed_response')
      self:scheduleRetry()
    end
  elseif status == 429 or (status == 503 and retryAfter(headers) >= 0) then
    local reason = extractError(body, 'rate_limited')
    self.log('warn', 'session creation rate-limited (' .. reason .. ')')
    self:emit('session_failed', reason)
    self:scheduleRetry(retryAfter(headers))
  elseif status == 403 and (extractError(body, '') == 'invalid_playtest_token' or extractError(body, '') == 'playtest_job_closed') then
    local reason = extractError(body, 'http_403')
    self.playtestBlocked = true
    self.log('error', 'playtest session refused (' .. reason .. ')')
    self:emit('session_failed', reason)
  elseif status == 403 and extractError(body, '') == 'tracking_disabled' then
    self:emit('session_failed', 'tracking_disabled')
    self:onServerTrackingDisabled()
    return
  elseif status == 401 or status == 403 then
    -- The key itself was refused (revoked, rotated, wrong): retrying cannot
    -- help, so the run ends here.
    self:emit('session_failed', extractError(body, 'http_' .. tostring(status)))
    self:onKeyRefused(status, body)
    return
  else
    local reason = extractError(body, status == 0 and 'network_error' or ('http_' .. tostring(status)))
    self.log('error', 'session creation failed (' .. reason .. ')')
    self:emit('session_failed', reason)
    self:scheduleRetry()
  end

  -- Quitting and no session came of it: nothing more can be sent.
  if self.quitting and status ~= 201 then self:finishQuit() end
end

--- Keeps the session answer's origin (exactly as received) and signing
--- secret (in memory only), and the clock correction for signatures.
--- Events queued while no session was open belong to this one.
function Core:adoptSessionExtras(answer)
  self.sessionOrigin = type(answer.origin) == 'table' and answer.origin or nil
  self.signingSecret = nil
  local signing = answer.signing
  if type(signing) == 'table' and signing.algorithm == 'HMAC-SHA256' and signing.version == 1 and type(signing.secret) == 'string' then
    self.signingSecret = signing.secret
    self.clockOffset = type(signing.serverTime) == 'number' and (signing.serverTime - self.time()) or 0
  end
  if self.sessionOrigin then
    local adopted = false
    for _, e in ipairs(self.pending) do
      if e._origin == nil then e._origin = self.sessionOrigin; adopted = true end
    end
    if adopted then self:saveQueue() end
  end
end

--- The session fields the engine reports, cleaned: each a trimmed,
--- printable string of at most DEVICE_FIELD_MAX_CHARS characters; an empty
--- or missing one is left out.
function Core.deviceFields(raw)
  local out = {}
  if type(raw) ~= 'table' then return out end
  for _, key in ipairs({ 'model', 'osVersion', 'gpu' }) do
    local value = raw[key]
    if type(value) == 'string' then
      value = value:gsub('[%z\1-\31\127]', ''):match('^%s*(.-)%s*$')
      value = Typed.cut(value, Core.DEVICE_FIELD_MAX_CHARS):match('^(.-)%s*$')
      if value ~= '' then out[key] = value end
    end
  end
  return out
end

--- Schedules the next attempt. A server's Retry-After is obeyed exactly and
--- an explicit flush() never cuts it short; otherwise the wait is the
--- backoff, multiplied by a random factor from 0.5 up to 1, so many games
--- that failed together do not retry together. Never less than half a
--- second; never more than 5 minutes.
function Core:scheduleRetry(explicitWait)
  local wait
  if explicitWait and explicitWait > 0 then
    wait = explicitWait
    self.retryFromServer = true
  else
    local factor = Core.JITTER_MIN_FACTOR + (1 - Core.JITTER_MIN_FACTOR) * self.random()
    wait = math.min(self.backoff, Core.MAX_BACKOFF_SECONDS) * factor
    self.backoff = math.min(self.backoff * 2, Core.MAX_BACKOFF_SECONDS)
    self.retryFromServer = false
  end
  self.retryAt = self.now() + math.max(wait, Core.MIN_RETRY_SECONDS)
end

-- ---------------------------------------------------------------- tracking

-- Config is scoped to the same identity/context that determines assignments.
function Core:currentConfigScope()
  return json.encode({ self.apiUrl, self.ingestKey, self.deviceId, self.playtestToken ~= '' and 'ravensight-playtest' or self.platform, self.gameVersion })
end
function Core:cachedConfig()
  if not self.trackingEnabled or self.keyRefused or self.playtestBlocked or not self.serverTrackingEnabled or self.ingestKey == '' or self.deviceId == '' then return nil end
  local scope = self:currentConfigScope()
  if self.configScope == scope then return self.configDocument end
  self.configScope, self.configDocument = scope, nil
  if self.playtestToken == '' then
    local ok, text = pcall(self.storage.read, 'ravensight_config.json')
    local cached = ok and type(text) == 'string' and #text <= 435000 and json.decode(text) or nil
    if type(cached) == 'table' and cached.scope == scope and Config.valid(cached.document) then self.configDocument = cached.document end
  end
  return self.configDocument
end
--- A remote config value. A read is how the game uses a value, so the
--- first read in a session marks every running experiment in the config as
--- exposed: from then on every event queued carries rs_exp_<key> =
--- <variant>, and one rs_exposure event is sent at that moment. A fetch
--- alone tags nothing.
function Core:getConfig(key, fallback)
  local cached = self:cachedConfig()
  self:noteExposure(cached)
  return Config.get(cached and cached.values, key, fallback)
end

function Core:noteExposure(document)
  if not document or not self.trackingEnabled then return end
  local newly = false
  for _, row in ipairs(document.experiments or {}) do
    if not self.exposed[row.key] then self.exposed[row.key] = row.variant; newly = true end
  end
  if newly then self:track('rs_exposure', {}) end
end

local VARIANT = '^[a-z][a-z0-9_%-]*$'

--- Adds rs_exp_<key> for each exposed experiment still in the config (one
--- that stopped is no longer tagged). A well-formed value the game set
--- itself is left alone; a malformed one is replaced.
function Core:applyExposureTags(eventData)
  if next(self.exposed) == nil then return end
  local document = self:cachedConfig()
  for _, row in ipairs(document and document.experiments or {}) do
    if self.exposed[row.key] then
      local tag, current = 'rs_exp_' .. row.key, eventData['rs_exp_' .. row.key]
      if not (type(current) == 'string' and #current <= 40 and current:match(VARIANT)) then
        eventData[tag] = row.variant
      end
    end
  end
end

--- Starts experiment exposure over for a new session.
function Core:resetSessionScope()
  self.exposed = {}
end
function Core:fetchConfig()
  if not self.trackingEnabled or self.playerOptedOut or self.keyRefused or self.playtestBlocked or not self.serverTrackingEnabled or self.quitting or self.ingestKey == '' or self.deviceId == '' or self.configPending then return false end
  local cached = self:cachedConfig()
  local scope = self:currentConfigScope()
  self.configGeneration = self.configGeneration + 1
  local generation = self.configGeneration
  self.configPending = true
  local headers = { ['X-API-Key'] = self.ingestKey }
  if cached then headers['If-None-Match'] = cached.etag end
  local platform = self.playtestToken ~= '' and 'ravensight-playtest' or self.platform
  self.send({ method = 'GET', url = self.apiUrl .. '/api/v1/ingest/config?deviceId=' .. Config.encode(self.deviceId) .. '&platform=' .. Config.encode(platform) .. '&gameVersion=' .. Config.encode(self.gameVersion), headers = headers, timeout = 5 }, function(status, body)
    if generation ~= self.configGeneration then return end
    self.configPending = false
    if not self.trackingEnabled or self.playerOptedOut or self.keyRefused or not self.serverTrackingEnabled or scope ~= self:currentConfigScope() then return end
    local source = self:cachedConfig() and 'cache' or 'default'
    local document = status == 200 and type(body) == 'string' and #body <= 430000 and json.decode(body) or nil
    if Config.valid(document) then
      self.configDocument, self.configScope = document, scope
      source = 'network'
      if self.playtestToken == '' then pcall(self.storage.write, 'ravensight_config.json', json.encode({ scope = scope, document = document })) end
    end
    self:emit('config_ready', source)
  end)
  return true
end

--- Queue an event. Safe before the session is ready.
function Core:track(name, data)
  if not self.trackingEnabled then return end
  assert(type(name) == 'string' and name ~= '', 'ravensight.track: the event name must be a non-empty string')
  if data ~= nil and type(data) ~= 'table' then
    error('ravensight.track: data must be a table or nil', 2)
  end
  local queued = self:enqueue(name, data or {})
  if not queued then return end
  self:emit('event_tracked', name, queued)

  -- A retry wait is running: let it send, so backoff and Retry-After hold.
  if self.retryAt then return end
  if self:isSessionValid() then
    -- Batched: update() sends once flushInterval has passed since the first
    -- waiting event, or now when a full request's worth is waiting.
    if #self.pending >= Core.MAX_BATCH_SIZE then self:flushPending() end
  elseif not self.sessionPending and not self.playtestBlocked and not self.settingsPending then
    -- While the settings check is out, its answer opens the session.
    self:startSession()
  end
end

local function shallowCopy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

--- The next rs_event_id: unique per event, and kept inside the event's data
--- so a saved and reloaded queue resends the same id.
function Core:nextEventId()
  if not self.eventNonce then self.eventNonce = self.randomHex(4) end
  self.eventCounter = self.eventCounter + 1
  return Core.eventId(self.deviceId, self.startTime or self.time(), self.eventNonce, self.eventCounter)
end

--- Queues an error the SDK captured by itself (ravensight/errors.lua built
--- the data). It goes behind every gameplay event, starts no session and no
--- send of its own, and fires no event_tracked. Returns the queued data, or
--- nil when capture is not allowed or the event is too large.
function Core:enqueueError(name, data)
  if not self:errorCaptureAllowed() then return nil end
  return self:enqueue(name, data)
end

--- The first queued automatic error that is not in the batch in flight.
function Core:firstQueuedError()
  local floor = self.flushInProgress and self.inflightSize or 0
  for i = floor + 1, #self.pending do
    if Errors.isAutomatic(self.pending[i].data) then return i end
  end
  return nil
end

--- Queues one event, or returns nil when it is too large to send.
function Core:enqueue(name, data)
  -- Never mutate the caller's table.
  local eventData = shallowCopy(data)
  self:applyExposureTags(eventData)
  if self.playtestTags then
    for k, v in pairs(self.playtestTags) do eventData[k] = v end
  end
  eventData.rs_event_id = self:nextEventId()
  local timestamp = self.timeMs()
  if Core.eventBytes(eventData) > Core.MAX_EVENT_BYTES then
    if not self.warnedTooLarge then
      self.warnedTooLarge = true
      self.log('warn', 'dropped event "' .. name .. '": larger than ' .. Core.MAX_EVENT_BYTES .. ' bytes as JSON (further drops are not logged)')
    end
    self:emit('flush_failed', 'event_too_large')
    return nil
  end
  -- Full: an automatic error goes first, so a storm of them can never push
  -- gameplay out; an automatic error never evicts a gameplay event, it is
  -- dropped itself.
  local automatic = Errors.isAutomatic(eventData)
  -- Nothing in the batch in flight is ever evicted: with nothing else to
  -- make room, the incoming event is the one dropped.
  while #self.pending >= self:queueCap() do
    local victim = self:firstQueuedError()
    if not victim and not automatic then victim = self:oldestOutsideFlight() end
    self.deliveryStats.dropped_overflow = self.deliveryStats.dropped_overflow + 1
    if not victim then return nil end
    table.remove(self.pending, victim)
  end
  -- Gameplay events keep their place ahead of automatic errors. The session
  -- it was queued under goes with it, so a later session can send it with
  -- its origin; events queued before a session opens join the next one.
  local position = #self.pending + 1
  if not automatic then position = self:firstQueuedError() or position end
  table.insert(self.pending, position, { event = name, data = eventData, timestamp = timestamp, _origin = self.sessionOrigin })
  if not self.firstQueuedAt then self.firstQueuedAt = self.now() end
  self.queueDirty = true
  return eventData
end

--- The queue cap: maxQueueSize, at most 500.
function Core:queueCap()
  return math.max(1, math.min(self.maxQueueSize, Core.QUEUE_MAX_EVENTS))
end

--- The oldest event outside the batch in flight, or nil.
function Core:oldestOutsideFlight()
  local first = (self.flushInProgress and self.inflightSize or 0) + 1
  if first <= #self.pending then return first end
  return nil
end

--- Drops events past the cap, automatic errors first, then the oldest,
--- never from the batch in flight, and counts them.
function Core:trimQueue()
  while #self.pending > self:queueCap() do
    local victim = self:firstQueuedError() or self:oldestOutsideFlight()
    if not victim then return end
    table.remove(self.pending, victim)
    self.deliveryStats.dropped_overflow = self.deliveryStats.dropped_overflow + 1
  end
end

--- Events the SDK let go of since launch, by reason: dropped_overflow (past
--- the 500 event cap, oldest first), dropped_too_old (older than 89 days
--- when the queue was read) and dropped_refused (refused by the server).
function Core:getDeliveryStats()
  return shallowCopy(self.deliveryStats)
end

--- Send what is queued now. Cuts a backoff wait short; a server's
--- Retry-After wait always holds.
function Core:flush()
  if self.retryAt and self.retryFromServer then return end
  self.retryAt = nil
  if not self:isSessionValid() then
    if self.trackingEnabled and not self.sessionPending and not self.settingsPending and #self.pending > 0 then self:startSession() end
    return
  end
  self:flushPending()
end

local function slice(list, from, to)
  local out = {}
  for i = from, math.min(to, #list) do out[#out + 1] = list[i] end
  return out
end

function Core:flushPending()
  if not self.trackingEnabled then return end
  if self.flushInProgress or #self.pending == 0 or not self:isSessionValid() then return end
  self.flushInProgress = true
  self.firstQueuedAt = nil

  local size = math.min(Core.MAX_BATCH_SIZE, #self.pending)
  if self.splitBatchSize > 0 then size = math.min(size, self.splitBatchSize) end
  self.inflightSize = size
  local wire = {}
  for i = 1, size do wire[i] = self:wireEvent(self.pending[i]) end
  local generation = self.queueGeneration
  local body = json.encode({ events = wire })
  local headers = self:signedHeaders({ ['Content-Type'] = 'application/json', ['X-Session-Token'] = self.sessionToken }, body)

  local payload = self:encodeBody(body, headers)
  self.lastBatchCompressed = headers['Content-Encoding'] == 'gzip'
  self.send({
    method = 'POST',
    url = self.apiUrl .. '/api/v1/track/batch',
    headers = headers,
    body = payload,
  }, function(status, responseBody, responseHeaders)
    self:onBatchResponse(status, responseBody, responseHeaders, size, generation)
  end)
end

--- One queued event as it goes on the wire: name, data and timestamp, plus
--- the origin of the session it was queued under when that is not the
--- current session (copied verbatim, never rebuilt).
function Core:wireEvent(e)
  local out = { event = e.event, data = e.data, timestamp = e.timestamp }
  local origin = e._origin
  if type(origin) == 'table' and origin.session ~= (self.sessionOrigin and self.sessionOrigin.session) then
    out.origin = origin
  end
  return out
end

--- The headers, signed when the session gave a secret: X-Ravensight-Timestamp
--- (the device clock corrected by the server's) and an HMAC-SHA256 over the
--- uncompressed body.
function Core:signedHeaders(headers, body)
  if not self.signingSecret then return headers end
  local t = math.floor(self.time() + self.clockOffset)
  headers['X-Ravensight-Timestamp'] = string.format('%d', t)
  headers['X-Ravensight-Signature'] = 'v1=' .. Hmac.sign(self.signingSecret, t, body, self.sha256)
  return headers
end

--- The body as sent: gzip compressed, with Content-Encoding added to the
--- headers, when it is at least GZIP_MIN_BYTES and the platform can
--- compress; otherwise the text.
function Core:encodeBody(body, headers)
  if self.sendPlain or not self.gzip or #body < Core.GZIP_MIN_BYTES then return body end
  local ok, compressed = pcall(self.gzip, body)
  if not ok or type(compressed) ~= 'string' or compressed == '' then return body end
  headers['Content-Encoding'] = 'gzip'
  return compressed
end

--- Drops the first `count` queued events (delivered or refused) and saves
--- the queue before anything else, so a crash right after the answer resends
--- as little as possible.
function Core:dropFront(count)
  self.pending = slice(self.pending, count + 1, #self.pending)
  self:saveQueue()
end

function Core:countRefused(count, reason)
  self.deliveryStats.dropped_refused = self.deliveryStats.dropped_refused + count
  self.log('warn', 'dropped ' .. count .. ' event(s) the server refused (' .. reason .. ')')
  self:emit('flush_failed', reason)
end

function Core:onBatchResponse(status, body, headers, size, generation)
  -- The queue this batch came from was discarded since it went out.
  if generation ~= self.queueGeneration then return end
  self.flushInProgress = false
  self.inflightSize = 0
  local parsed = json.decode(body or '')
  local errorCode = type(parsed) == 'table' and parsed.error ~= nil and tostring(parsed.error) or ''
  if status ~= 413 and status ~= 415 then self.sendPlain = false end

  if status >= 200 and status < 300 then
    self:dropFront(size)
    self.backoff = Core.DEFAULT_RETRY_SECONDS
    self.splitBatchSize = 0
    self.reauthAttempts = 0
    self.log('info', 'events_flushed ' .. size)
    self:emit('events_flushed', size)
    if #self.pending > 0 then self:flushPending() end
  elseif status == 401 then
    -- The session expired, was revoked or a signature was refused: open a
    -- new session (and secret) once; a second 401 in a row waits.
    self.sessionToken = ''
    self.sessionExpiresAt = 0
    self.signingSecret = nil
    self.reauthAttempts = self.reauthAttempts + 1
    if self.reauthAttempts <= Core.MAX_REAUTH_ATTEMPTS then
      self.log('warn', 'session refused (' .. (errorCode ~= '' and errorCode or 'http_401') .. '), opening a new one')
      self:startSession()
    else
      self:emit('flush_failed', errorCode ~= '' and errorCode or 'http_401')
      self:scheduleRetry()
    end
  elseif status == 403 and errorCode == 'tracking_disabled' then
    self:onServerTrackingDisabled()
    return
  elseif status == 403 and (errorCode == 'invalid_playtest_token' or errorCode == 'playtest_job_closed') then
    self.playtestBlocked = true
    self.trackingEnabled = false
    self:clearQueue()
    self:emit('flush_failed', errorCode)
  elseif status == 403 then
    -- Keep the events and stop until the next launch.
    self:onKeyRefused(status, body)
    return
  elseif status == 429 or (status == 503 and retryAfter(headers) >= 0) then
    local reason = errorCode ~= '' and errorCode or 'rate_limited'
    self.log('warn', 'track/batch rate-limited (' .. reason .. ')')
    self:emit('flush_failed', reason)
    self:scheduleRetry(retryAfter(headers))
  elseif status == 400 or status == 413 or status == 415 then
    self:onBatchRefused(status, errorCode, parsed, size)
    if #self.pending > 0 then self:flushPending() end
  else
    local reason = errorCode ~= '' and errorCode or (status == 0 and 'network_error' or ('http_' .. tostring(status)))
    self.log('warn', 'batch flush failed (' .. reason .. '), will retry')
    self:emit('flush_failed', reason)
    self:scheduleRetry()
  end

  if self.quitting then
    if not self.flushInProgress and not self.sessionPending then self:finishQuit() end
  end
end

--- A 400, 413 or 415 for the `size` events at the queue's front:
---   a 400 naming an event by index drops that event, the rest are resent;
---   batch_too_large or a 413 halves the batch, and drops one event that is
---   still too large;
---   a 415 (or a 413 for one event) is resent uncompressed once, then dropped;
---   any other 400 drops the request's events (only batch_too_large and a
---   413 halve a batch).
function Core:onBatchRefused(status, errorCode, parsed, size)
  local reason = errorCode ~= '' and errorCode or ('http_' .. tostring(status))
  local index = type(parsed) == 'table' and parsed.index
  if status == 400 and type(index) == 'number' and index % 1 == 0 and index >= 0 and index < size then
    table.remove(self.pending, index + 1)
    self:saveQueue()
    self.splitBatchSize = 0
    self:countRefused(1, reason)
    return
  end
  if status == 415 or (status == 413 and size <= 1) then
    -- A 413 for one event that went uncompressed is never retried as is.
    if not self.sendPlain and (status == 415 or self.lastBatchCompressed) then
      self.sendPlain = true
      return
    end
    self.sendPlain = false
    self:dropFront(size)
    self:countRefused(size, reason)
    return
  end
  local halves = status == 413 or errorCode == 'batch_too_large'
  if halves and size > 1 then
    self.splitBatchSize = math.max(1, math.floor(size / 2))
    self.log('warn', 'batch refused (' .. reason .. '), splitting to ' .. self.splitBatchSize)
    return
  end
  self:dropFront(size)
  self:countRefused(size, reason)
end

-- ---------------------------------------------------------------- feedback

--- True when category is absent or one the feedback endpoint accepts.
function Core.isFeedbackCategory(category)
  return category == nil or category == '' or Core.FEEDBACK_CATEGORIES[category] == true
end

--- True when rating is absent or a whole number from 1 to 5.
function Core.isFeedbackRating(rating)
  return rating == nil or (type(rating) == 'number' and rating >= 1 and rating <= 5 and rating == math.floor(rating))
end

--- Send free-form player feedback. category and rating (1 to 5) are optional;
--- category is one of bug, suggestion, complaint, praise, playtest, other.
--- Returns true when the request went out, or false and a reason when it was
--- refused here. The server's answer arrives on feedback_submitted or
--- feedback_failed.
function Core:submitFeedback(message, category, rating)
  if not self.trackingEnabled then
    self:emit('feedback_failed', 'tracking_disabled')
    return false, 'tracking_disabled'
  end
  if type(message) ~= 'string' or message == '' then
    self:emit('feedback_failed', 'empty_message')
    return false, 'empty_message'
  end
  if not Core.isFeedbackCategory(category) then
    self.log('warn', 'feedback_rejected invalid_category ' .. tostring(category))
    self:emit('feedback_failed', 'invalid_category')
    return false, 'invalid_category'
  end
  if not Core.isFeedbackRating(rating) then
    self.log('warn', 'feedback_rejected invalid_rating ' .. tostring(rating))
    self:emit('feedback_failed', 'invalid_rating')
    return false, 'invalid_rating'
  end
  if not self:isSessionValid() then
    self:emit('feedback_failed', 'no_session')
    if not self.sessionPending then self:startSession() end
    return false, 'no_session'
  end
  local payload = { message = message }
  if category and category ~= '' then payload.category = category end
  if rating then payload.rating = rating end
  self.send({
    method = 'POST',
    url = self.apiUrl .. '/api/v1/feedback',
    headers = { ['Content-Type'] = 'application/json', ['X-Session-Token'] = self.sessionToken },
    body = json.encode(payload),
  }, function(status, body)
    if status == 201 then
      self:emit('feedback_submitted')
    else
      self:emit('feedback_failed', extractError(body, status == 0 and 'network_error' or ('http_' .. tostring(status))))
    end
  end)
  return true
end

-- ----------------------------------------------------------------- privacy

--- Player opt-out, saved across launches. false drops the queue and stops
--- every request; true re-reads the kill switch and starts again.
function Core:setTrackingEnabled(enabled)
  if enabled and not self.playerOptedOut then return end
  self.playerOptedOut = not enabled
  if self.playerOptedOut then
    Core.saveChoice(self.storage, self.consent, false)
    self.trackingEnabled = false
    self:dropSession()
    self:clearQueue(true)
    self.retryAt = nil
    self.log('info', 'tracking disabled by player opt-out')
    self:emit('tracking_disabled', 'player')
  else
    Core.saveChoice(self.storage, self.consent, true)
    -- With opt_in this is the first moment an id may exist.
    self:loadIdentity()
    if self.keyRefused then
      self.log('info', 'the choice is saved; the key was refused, so nothing is sent this run')
      return
    end
    -- Collect from this moment, so events tracked right after the yes are
    -- queued; the settings answer clears them if the server says no.
    self.trackingEnabled = self.serverTrackingEnabled
    self:checkServerSettings()
  end
end

function Core:isTrackingEnabled()
  return self.trackingEnabled
end

--- A fresh random device id, a dropped session and an empty queue. A no-op
--- in a playtest run, whose id is never saved.
function Core:resetDeviceId()
  if self.playtestToken ~= '' then return end
  -- A new identity is a new install for attribution and a new session.
  self.storage.remove(Core.ATTRIBUTION_FILE)
  self:resetSessionScope()
  if self.consent == Core.CONSENT_OPT_IN and self.playerOptedOut then
    -- Not opted in: forget any old id and make none until the player says yes.
    self.storage.remove(Core.DEVICE_ID_FILE)
    self.deviceId = ''
    self.identityLoaded = false
    self:clearQueue(true)
    return
  end
  self.storage.remove(Core.DEVICE_ID_FILE)
  self.deviceId = self:generateDeviceId()
  self.storage.write(Core.DEVICE_ID_FILE, self.deviceId)
  self:dropSession()
  self:clearQueue(true)
end

function Core:dropSession()
  self.sessionToken = ''
  self.sessionExpiresAt = 0
  self.sessionOrigin = nil
  self.signingSecret = nil
  self.sessionPending = false
  self.sessionGeneration = self.sessionGeneration + 1
  self.configGeneration = self.configGeneration + 1
  self.configPending = false
  self.configDocument, self.configScope = nil, nil
end

--- Discards every queued event from memory. `forget` also deletes the saved
--- queue (the player's opt-out, a reset identity); otherwise what is queued
--- is written first and the file stays for the next launch.
function Core:clearQueue(forget)
  if forget then
    if self.playtestToken == '' then self.storage.remove(Core.queueFile(self.ingestKey)) end
  else
    self:saveQueue(true)
  end
  self.pending = {}
  self.queueDirty = false
  self.firstQueuedAt = nil
  self.queueGeneration = self.queueGeneration + 1
  self.flushInProgress = false
  self.inflightSize = 0
  self.splitBatchSize = 0
end

--- The ingest key was refused (401, or a 403 that is not the kill switch or
--- a playtest refusal). Tracking stops for the rest of the process: no retry
--- loop on a revoked key. The queued events stay on disk for the next launch.
function Core:onKeyRefused(status, body)
  if self.keyRefused then return end
  self.keyRefused = true
  self.trackingEnabled = false
  self:dropSession()
  self:clearQueue()
  self.retryAt = nil
  self.log('error', 'the ingest key was refused (HTTP ' .. tostring(status) .. ', ' .. extractError(body, 'no reason given') .. '); nothing more is sent this run')
  self:emit('tracking_disabled', 'key')
  if self.quitting then self:finishQuit() end
end

function Core:onServerTrackingDisabled()
  self.serverTrackingEnabled = false
  self.trackingEnabled = false
  self:dropSession()
  self:clearQueue()
  self.retryAt = nil
  self.log('info', 'tracking disabled by server kill switch')
  self:emit('tracking_disabled', 'server')
  if self.quitting then self:finishQuit() end
end

-- ------------------------------------------------------------ saved queue

--- Reads the saved queue once, at start: its events go ahead of anything
--- queued this run. A missing, unreadable, malformed or unknown version file
--- is an empty queue. Version 1 groups have no origin. The queue file of 0.5
--- and earlier (a plain list) is read the same way and removed. Events older
--- than 89 days are dropped (dropped_too_old), and the oldest past the cap.
function Core:loadSavedQueue()
  if self.queueLoaded then return end
  self.queueLoaded = true
  local loaded, tooOld = {}, 0
  local cutoff = self.timeMs() - Core.QUEUE_MAX_AGE_MS
  local crashCutoff = self.timeMs() - Errors.PENDING_MAX_AGE * 1000
  local function take(e, origin)
    if type(e) ~= 'table' or type(e.event) ~= 'string' or e.event == '' or type(e.timestamp) ~= 'number' then return end
    -- A timestamp below 10^12 is in seconds (an older SDK's queue).
    local ms = e.timestamp >= 1e12 and e.timestamp or e.timestamp * 1000
    if ms < cutoff then tooOld = tooOld + 1 return end
    -- A saved crash older than Errors.PENDING_MAX_AGE is deleted unsent.
    if type(e.data) == 'table' and e.data.rs_source == 'crash' and ms < crashCutoff then tooOld = tooOld + 1 return end
    -- Each event keeps its rs_event_id: it lives inside data.
    loaded[#loaded + 1] = { event = e.event, data = type(e.data) == 'table' and e.data or {}, timestamp = e.timestamp, _origin = origin or false }
  end
  local legacy = self.storage.read(Core.LEGACY_QUEUE_FILE)
  if legacy then
    local list = json.decode(legacy)
    if type(list) == 'table' then
      for _, e in ipairs(list) do take(e, nil) end
    end
  end
  local text = self.storage.read(Core.queueFile(self.ingestKey))
  local doc = text and json.decode(text)
  if type(doc) == 'table' and (doc.version == 1 or doc.version == 2) and type(doc.groups) == 'table' then
    for _, group in ipairs(doc.groups) do
      if type(group) == 'table' and type(group.events) == 'table' then
        local origin = doc.version == 2 and type(group.origin) == 'table' and group.origin or nil
        for _, e in ipairs(group.events) do take(e, origin) end
      end
    end
  end
  self.deliveryStats.dropped_too_old = self.deliveryStats.dropped_too_old + tooOld
  for _, e in ipairs(self.pending) do loaded[#loaded + 1] = e end
  -- Gameplay goes before captured errors (nothing is in flight yet).
  local gameplay, captures = {}, {}
  for _, e in ipairs(loaded) do
    local list = Errors.isAutomatic(e.data) and captures or gameplay
    list[#list + 1] = e
  end
  for _, e in ipairs(captures) do gameplay[#gameplay + 1] = e end
  self.pending = gameplay
  self:trimQueue()
  if #self.pending > 0 and not self.firstQueuedAt then self.firstQueuedAt = self.now() end
  self:saveQueue()
  if legacy then self.storage.remove(Core.LEGACY_QUEUE_FILE) end
end

--- Writes the queue now, as format version 2: one group per session with
--- that session's origin exactly as received. The storage's replace (a
--- temporary file renamed over the old one) is used where it exists, so a
--- partial file never replaces a good one. An empty queue deletes the file.
--- Only while collecting (or `stopping`, the last write before the queue is
--- let go of), and never in a playtest run.
function Core:saveQueue(stopping)
  self.queueDirty = false
  if self.playtestToken ~= '' or not self.queueLoaded or not (stopping or self.trackingEnabled) then return end
  local name = Core.queueFile(self.ingestKey)
  if #self.pending == 0 then
    self.storage.remove(name)
    return
  end
  local groups, last = {}, nil
  for _, e in ipairs(self.pending) do
    local origin = type(e._origin) == 'table' and e._origin or nil
    local session = origin and origin.session or ''
    if #groups == 0 or session ~= last then
      groups[#groups + 1] = { origin = origin, events = {} }
      last = session
    end
    local events = groups[#groups].events
    local data = e.data
    if type(data) == 'table' and data.rs_trail ~= nil then
      -- A capture's trail is never written to the queue file.
      data = {}
      for k, v in pairs(e.data) do if k ~= 'rs_trail' then data[k] = v end end
    end
    events[#events + 1] = { event = e.event, timestamp = e.timestamp, data = data }
  end
  local text = json.encode({ version = Core.QUEUE_FORMAT_VERSION, groups = groups })
  local replace = self.storage.replace or self.storage.write
  pcall(replace, name, text)
end

-- ------------------------------------------------------------- attribution

--- Where this install was acquired (see Typed.attribution), sent once per
--- install: a flag saved beside the device id stops later calls, and
--- resetDeviceId() clears it. Returns true when queued, or false and why.
function Core:setAttribution(attribution)
  if not self.trackingEnabled then return false, 'tracking_disabled' end
  if self.storage.read(Core.ATTRIBUTION_FILE) then return false, 'already_sent' end
  local name, props = Typed.attribution(attribution)
  if not name then
    self.log('warn', 'attribution event not sent: ' .. props)
    return false, props
  end
  self:track(name, props)
  if self.playtestToken == '' then self.storage.write(Core.ATTRIBUTION_FILE, '1') end
  return true
end

-- -------------------------------------------------------------------- quit

--- Starts the quit sequence: records game_exited and flushes. Returns true
--- when the caller should hold the quit open until quitReady() says so.
function Core:beginQuit()
  if self.quitReady then return false end
  if self.quitting then return true end
  self.quitting = true
  if self.trackingEnabled then
    self:emit('event_tracked', 'game_exited', self:enqueue('game_exited', {}))
    self:saveQueue()
  end
  local canSend = self:isSessionValid() or self.sessionPending
  if not self.trackingEnabled or #self.pending == 0 or not canSend then
    self:finishQuit()
    return false
  end
  self.quitDeadline = self.now() + Core.QUIT_FLUSH_TIMEOUT_SECONDS
  self:flushPending()
  return not self.quitReady
end

function Core:finishQuit()
  if self.quitReady then return end
  self.quitReady = true
  self:saveQueue()
end

return Core
