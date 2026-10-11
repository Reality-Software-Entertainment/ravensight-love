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
--   * a 400 batch is halved until the one bad event is isolated and dropped
--   * the player's opt-out is saved and honoured before anything is sent
--
-- One addition: events still queued when the game quits are saved and sent
-- on the next launch, because a LÖVE game on a desktop is often closed while
-- offline.
--
-- MIT licensed, part of ravensight-love.

local json = require(((...):gsub('core$', 'json')))

local Core = {}
Core.__index = Core

Core.VERSION = '0.2.0'
Core.MAX_BATCH_SIZE = 50
Core.DEFAULT_RETRY_SECONDS = 10
Core.MAX_BACKOFF_SECONDS = 300
Core.QUIT_FLUSH_TIMEOUT_SECONDS = 1.5
Core.DEFAULT_FLUSH_INTERVAL_SECONDS = 2
Core.DEFAULT_MAX_QUEUE_SIZE = 500

--- The categories the feedback endpoint accepts. Anything else is refused
--- before it is sent.
Core.FEEDBACK_CATEGORIES = {
  bug = true, suggestion = true, complaint = true, praise = true, playtest = true, other = true,
}

Core.DEVICE_ID_FILE = 'ravensight_device_id'
Core.OPTOUT_FILE = 'ravensight_optout'
Core.QUEUE_FILE = 'ravensight_queue.json'

local EVENTS = {
  session_ready = true, session_failed = true, tracking_disabled = true,
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
---   time()                          unix seconds, for timestamps and expiry
---   storage                         {read(name), write(name, text), remove(name)}
---   randomHex(bytes)                cryptographically random lowercase hex
---   platform, osName                e.g. "macOS" and "macos"
---   log(level, message)             "info", "warn" or "error"
---   playtest                        {token, run_id, job_id, persona, tier} or nil
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
  self.storage = deps.storage or { read = noop, write = noop, remove = noop }
  self.randomHex = assert(deps.randomHex, 'ravensight: core needs randomHex')
  self.platform = deps.platform or 'unknown'
  self.osName = deps.osName or 'unknown'
  self.log = deps.log or noop

  self.listeners = {}
  self.deviceId = ''
  self.sessionToken = ''
  self.sessionExpiresAt = 0
  self.sessionPending = false
  self.sessionGeneration = 0
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
  if self.playtestToken == '' then
    self.deviceId = self:loadOrCreateDeviceId()
    self.playerOptedOut = self.storage.read(Core.OPTOUT_FILE) ~= nil
    self.trackingEnabled = not self.playerOptedOut
    if not self.playerOptedOut then self:loadSavedQueue() end
  end
  if self.playerOptedOut then
    -- Nothing leaves the device, not even the settings check.
    self.log('info', 'tracking disabled by player opt-out')
    self:emit('tracking_disabled', 'player')
  else
    self:checkServerSettings()
  end
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
  self.send({
    method = 'GET',
    url = self.apiUrl .. '/api/v1/settings',
    headers = { ['X-API-Key'] = self.ingestKey },
  }, function(status, body)
    if status == 200 then
      local parsed = json.decode(body or '')
      if type(parsed) == 'table' and parsed.trackingEnabled ~= nil then
        self.serverTrackingEnabled = parsed.trackingEnabled == true
      end
    else
      self.log('warn', 'could not fetch settings (HTTP ' .. tostring(status) .. '); assuming tracking enabled')
    end
    self:afterSettingsChecked()
  end)
end

function Core:afterSettingsChecked()
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
  self.send({
    method = 'POST',
    url = self.apiUrl .. '/api/v1/session',
    headers = headers,
    body = json.encode({ deviceId = self.deviceId, gameVersion = self.gameVersion, platform = platform }),
  }, function(status, body, responseHeaders)
    self:onSessionResponse(status, body, responseHeaders, generation)
  end)
end

local function extractError(body, fallback)
  local parsed = json.decode(body or '')
  if type(parsed) == 'table' and parsed.error ~= nil then return tostring(parsed.error) end
  return fallback
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
      self.backoff = Core.DEFAULT_RETRY_SECONDS
      self.log('info', 'session ready')
      self:emit('session_ready')
      self:flushPending()
    else
      self.log('error', 'malformed session response')
      self:emit('session_failed', 'malformed_response')
      self:scheduleRetry()
    end
  elseif status == 429 then
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
  else
    local reason = extractError(body, status == 0 and 'network_error' or ('http_' .. tostring(status)))
    self.log('error', 'session creation failed (' .. reason .. ')')
    self:emit('session_failed', reason)
    self:scheduleRetry()
  end

  -- Quitting and no session came of it: nothing more can be sent.
  if self.quitting and status ~= 201 then self:finishQuit() end
end

function Core:scheduleRetry(explicitWait)
  local wait = (explicitWait and explicitWait > 0) and explicitWait or self.backoff
  self.backoff = math.min(self.backoff * 2, Core.MAX_BACKOFF_SECONDS)
  self.retryAt = self.now() + math.max(wait, 0.5)
end

-- ---------------------------------------------------------------- tracking

--- Queue an event. Safe before the session is ready.
function Core:track(name, data)
  if not self.trackingEnabled then return end
  assert(type(name) == 'string' and name ~= '', 'ravensight.track: the event name must be a non-empty string')
  if data ~= nil and type(data) ~= 'table' then
    error('ravensight.track: data must be a table or nil', 2)
  end
  local queued = self:enqueue(name, data or {})
  self:emit('event_tracked', name, queued)

  -- A retry wait is running: let it send, so backoff and Retry-After hold.
  if self.retryAt then return end
  if self:isSessionValid() then
    -- Batched: update() sends once flushInterval has passed since the first
    -- waiting event, or now when a full request's worth is waiting.
    if #self.pending >= Core.MAX_BATCH_SIZE then self:flushPending() end
  elseif not self.sessionPending and not self.playtestBlocked then
    self:startSession()
  end
end

local function shallowCopy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

function Core:enqueue(name, data)
  while #self.pending >= self.maxQueueSize do
    table.remove(self.pending, 1)
  end
  local eventData = data
  if self.playtestTags then
    -- Never mutate the caller's table.
    eventData = shallowCopy(data)
    for k, v in pairs(self.playtestTags) do eventData[k] = v end
  end
  table.insert(self.pending, { event = name, data = eventData, timestamp = self.time() })
  if not self.firstQueuedAt then self.firstQueuedAt = self.now() end
  return eventData
end

function Core:flush()
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
  local batch = slice(self.pending, 1, size)
  local generation = self.queueGeneration

  self.send({
    method = 'POST',
    url = self.apiUrl .. '/api/v1/track/batch',
    headers = { ['Content-Type'] = 'application/json', ['X-Session-Token'] = self.sessionToken },
    body = json.encode({ events = batch }),
  }, function(status, body, headers)
    self:onBatchResponse(status, body, headers, size, generation)
  end)
end

function Core:dropFront(count)
  self.pending = slice(self.pending, count + 1, #self.pending)
end

function Core:onBatchResponse(status, body, headers, size, generation)
  -- The queue this batch came from was discarded since it went out.
  if generation ~= self.queueGeneration then return end
  self.flushInProgress = false

  if status == 202 then
    self:dropFront(size)
    self.backoff = Core.DEFAULT_RETRY_SECONDS
    self.splitBatchSize = 0
    self.log('info', 'events_flushed ' .. size)
    self:emit('events_flushed', size)
    if #self.pending > 0 then self:flushPending() end
  elseif status == 401 then
    self.log('warn', 'session invalid or expired, refreshing')
    self.sessionToken = ''
    self.sessionExpiresAt = 0
    self:startSession()
  elseif status == 403 and extractError(body, '') == 'tracking_disabled' then
    self:onServerTrackingDisabled()
    return
  elseif status == 429 then
    local reason = extractError(body, 'rate_limited')
    self.log('warn', 'track/batch rate-limited (' .. reason .. ')')
    self:emit('flush_failed', reason)
    self:scheduleRetry(retryAfter(headers))
  elseif status == 400 then
    -- One oversized event fails the whole batch: halve until it is alone,
    -- then drop it, so it never costs the events around it.
    local reason = extractError(body, 'http_400')
    if size <= 1 then
      self:dropFront(size)
      self.log('warn', 'dropped one rejected event (' .. reason .. ')')
      self:emit('flush_failed', reason)
      if #self.pending > 0 then self:flushPending() end
    else
      self.splitBatchSize = math.max(1, math.floor(size / 2))
      self.log('warn', 'batch rejected (' .. reason .. '), splitting to ' .. self.splitBatchSize)
      self:flushPending()
    end
  else
    local reason = extractError(body, status == 0 and 'network_error' or ('http_' .. tostring(status)))
    self.log('warn', 'batch flush failed (' .. reason .. '), will retry')
    self:emit('flush_failed', reason)
    self:scheduleRetry()
  end

  if self.quitting then
    local stillSending = #self.pending > 0 and (status == 202 or status == 400 or status == 401)
    if not stillSending then self:finishQuit() end
  end
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
    self.storage.write(Core.OPTOUT_FILE, '1')
    self.trackingEnabled = false
    self:dropSession()
    self:clearQueue()
    self.storage.remove(Core.QUEUE_FILE)
    self.retryAt = nil
    self.log('info', 'tracking disabled by player opt-out')
    self:emit('tracking_disabled', 'player')
  else
    self.storage.remove(Core.OPTOUT_FILE)
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
  self.storage.remove(Core.DEVICE_ID_FILE)
  self.deviceId = self:generateDeviceId()
  self.storage.write(Core.DEVICE_ID_FILE, self.deviceId)
  self:dropSession()
  self:clearQueue()
  self.storage.remove(Core.QUEUE_FILE)
end

function Core:dropSession()
  self.sessionToken = ''
  self.sessionExpiresAt = 0
  self.sessionPending = false
  self.sessionGeneration = self.sessionGeneration + 1
end

function Core:clearQueue()
  self.pending = {}
  self.firstQueuedAt = nil
  self.queueGeneration = self.queueGeneration + 1
  self.flushInProgress = false
  self.splitBatchSize = 0
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

function Core:loadSavedQueue()
  local text = self.storage.read(Core.QUEUE_FILE)
  if not text then return end
  self.storage.remove(Core.QUEUE_FILE)
  local saved = json.decode(text)
  if type(saved) ~= 'table' then return end
  for _, e in ipairs(saved) do
    if type(e) == 'table' and type(e.event) == 'string' and type(e.timestamp) == 'number' then
      table.insert(self.pending, { event = e.event, data = type(e.data) == 'table' and e.data or {}, timestamp = e.timestamp })
    end
  end
  while #self.pending > self.maxQueueSize do table.remove(self.pending, 1) end
end

function Core:saveQueue()
  -- A playtest run's events belong to that run and are never carried over.
  if self.playtestToken ~= '' or not self.trackingEnabled then return end
  if #self.pending == 0 then
    self.storage.remove(Core.QUEUE_FILE)
  else
    self.storage.write(Core.QUEUE_FILE, json.encode(self.pending))
  end
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
