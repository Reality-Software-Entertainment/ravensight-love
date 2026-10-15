-- ravensight: player analytics for LÖVE games.
--
--   local ravensight = require("ravensight")
--
--   function love.load()
--     ravensight.init({
--       apiUrl = "https://api.ravensight.io",
--       ingestKey = "gt_live_...",
--       gameVersion = "1.0.0",
--     })
--   end
--   function love.update(dt) ravensight.update(dt) end
--   function love.quit() return ravensight.quit() end
--
--   ravensight.track("level_start", { level = "forest_1" })
--
-- Works on LÖVE 11.x and 12.x, desktop (Windows, macOS, Linux). A love.js
-- web build goes through the page's JavaScript SDK instead (see
-- ravensight/web.lua). See README.md for the full reference and
-- https://ravensight.io/docs/#love-sdk.
--
-- MIT licensed, part of ravensight-love.

local modulePrefix = (...):gsub('init$', ''):gsub('%.?$', '.')
if modulePrefix == '.' then modulePrefix = '' end

local Core = require(modulePrefix .. 'core')
local json = require(modulePrefix .. 'json')

local ravensight = { VERSION = Core.VERSION }

local core          -- the desktop state machine, or the web bridge
local initialized = false
local inert = false -- started with no key: nothing is written or sent
local config
local worker, requestChannel, responseChannel
local nextRequestId = 0
local callbacks = {}
local localResults = {}
local syncTransport
local transportName
local warnedNoTransport = false
local holdingQuit = false

local function log(level, message)
  if level == 'info' and not (config and config.debug) then return end
  print('Ravensight: ' .. message)
end

-- -------------------------------------------------------------- platform

local OS_NAMES = {
  ['OS X'] = { 'macOS', 'macos' },
  Windows = { 'Windows', 'windows' },
  Linux = { 'Linux', 'linux' },
  Android = { 'Android', 'android' },
  iOS = { 'iOS', 'ios' },
  Web = { 'Web', 'web' },
}

local function systemName()
  return love.system and love.system.getOS() or 'unknown'
end

local function platformNames()
  local os = systemName()
  local names = OS_NAMES[os]
  if names then return names[1], names[2] end
  return os, (os:lower():gsub('[^a-z0-9]', ''))
end

local function toHex(bytes)
  return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

--- Cryptographically random bytes from the operating system, as hex.
local function randomHex(count)
  local f = io.open('/dev/urandom', 'rb')
  if f then
    local bytes = f:read(count)
    f:close()
    if bytes and #bytes == count then return toHex(bytes) end
  end
  local okFfi, ffi = pcall(require, 'ffi')
  if okFfi and ffi.os == 'Windows' then
    pcall(ffi.cdef, 'unsigned char SystemFunction036(void*, unsigned long);')
    local okLib, advapi = pcall(ffi.load, 'advapi32')
    if okLib then
      local buf = ffi.new('uint8_t[?]', count)
      if advapi.SystemFunction036(buf, count) ~= 0 then return toHex(ffi.string(buf, count)) end
    end
  end
  -- Last resort, and said out loud: LÖVE's generator is not cryptographic,
  -- so seed it from everything that differs between installs and launches.
  log('warn', 'no system random source; using a seeded generator for the device id')
  local seed = os.time() + math.floor((love.timer and love.timer.getTime() or os.clock()) * 1e6)
  local rng = love.math.newRandomGenerator(seed, tonumber(tostring({}):match('0x(%x+)') or '1', 16) % 2^31)
  local out = {}
  for i = 1, count do out[i] = string.char(rng:random(0, 255)) end
  return toHex(table.concat(out))
end

local storage = {
  read = function(name)
    if not love.filesystem.getInfo(name) then return nil end
    return love.filesystem.read(name)
  end,
  write = function(name, text) love.filesystem.write(name, text) end,
  remove = function(name) love.filesystem.remove(name) end,
}

-- --------------------------------------------------------------- playtest

local function commandLineValue(name)
  local prefix = '--' .. name .. '='
  for _, value in ipairs(arg or {}) do
    if type(value) == 'string' and value:sub(1, #prefix) == prefix then return value:sub(#prefix + 1) end
  end
  return nil
end

local function playtestFromEnvironment()
  local token = os.getenv('RAVENSIGHT_PLAYTEST_TOKEN') or commandLineValue('ravensight-playtest-token')
  if not token or token == '' then return nil end
  return {
    token = token,
    run_id = os.getenv('RAVENSIGHT_PLAYTEST_RUN_ID') or commandLineValue('ravensight-playtest-run-id'),
    job_id = os.getenv('RAVENSIGHT_PLAYTEST_JOB_ID'),
    persona = os.getenv('RAVENSIGHT_PLAYTEST_PERSONA'),
  }
end

-- ----------------------------------------------------------------- network

local function deliver(id, status, body, headers)
  local callback = callbacks[id]
  callbacks[id] = nil
  if callback then callback(status, body, headers) end
end

local function send(req, callback)
  nextRequestId = nextRequestId + 1
  local id = nextRequestId
  callbacks[id] = callback
  req.id = id
  req.timeout = config.timeout
  if requestChannel then
    requestChannel:push(json.encode(req))
  elseif syncTransport then
    -- No threads in this game: the request blocks this frame. Answers are
    -- still delivered from update(), never from inside the caller.
    local status, body, headers = syncTransport.request(req)
    table.insert(localResults, { id, status, body, headers })
  else
    table.insert(localResults, { id, 0, 'no_transport', {} })
  end
end

local function noteTransport(name)
  transportName = name
  if name then
    log('info', 'sending with ' .. name)
  elseif not warnedNoTransport then
    warnedNoTransport = true
    print('Ravensight: no way to make an HTTPS request on this system; events are kept and saved, nothing is sent. See the README, "How requests are sent".')
  end
end

local function pollResponses()
  if responseChannel then
    while true do
      local message = responseChannel:pop()
      if not message then break end
      local data = json.decode(message)
      if data and data.kind == 'ready' then
        noteTransport(data.transport)
      elseif data and data.kind == 'response' then
        deliver(data.id, data.status, data.body, data.headers or {})
      end
    end
  end
  while #localResults > 0 do
    local r = table.remove(localResults, 1)
    deliver(r[1], r[2], r[3], r[4])
  end
end

local function startNetwork()
  local threadsAvailable = love.thread ~= nil and not config.synchronous
  if threadsAvailable then
    local unique = tostring({}):match('0x(%x+)') or tostring(os.time())
    local requestName = 'ravensight_requests_' .. unique
    local responseName = 'ravensight_responses_' .. unique
    requestChannel = love.thread.getChannel(requestName)
    responseChannel = love.thread.getChannel(responseName)
    local path = modulePrefix:gsub('%.', '/') .. 'worker.lua'
    worker = love.thread.newThread(path)
    worker:start(modulePrefix, requestName, responseName, config.transport or '')
  else
    syncTransport = require(modulePrefix .. 'transport').select(config.transport)
    noteTransport(syncTransport and syncTransport.name or nil)
  end
end

-- ------------------------------------------------------------- public API

--- Starts the SDK. Call once, from love.load().
---   apiUrl        "https://api.ravensight.io", with or without /api/v1
---   ingestKey     your game's publishable key. Missing or empty, the SDK
---                 is inert on the desktop: no files, no network, every call
---                 a no-op. Not needed on the web, where the page owns it.
---   optional      true silences the one warning an inert start prints
---   consent       "opt_out" (default): on until the player opts out.
---                 "opt_in": nothing is sent, and no device id is made,
---                 until setTrackingEnabled(true). Saved as ravensight_optin.
---   distribution  a short label sent on the session, such as
---                 "native-release" or "web-itch", default none
---   gameVersion   reported with every session, default "1.0.0"
---   enabled       false sends and queues nothing for this run, and is not
---                 saved, default true
---   maxQueueSize  unsent events kept, oldest dropped first, default 500
---   flushInterval seconds an event waits to be batched, default 2
---   handleQuit    hold the quit for up to 1.5 s to send the last events,
---                 default true (needs love.quit to return ravensight.quit())
---   transport     "https", "winhttp", "libcurl" or "curl" to try first, or
---                 "web" for the love.js bridge (automatic on the web)
---   synchronous   send on the game's own thread, blocking, default false
---   timeout       seconds per request, default 15
---   debug         print informational messages too, default false
---
--- Returns nothing on the desktop. In a web build it returns
--- { sessionReady = false, reason = 'web_bridge' }, since the page's
--- JavaScript SDK opens the session. Started inert (no key, not on the web)
--- it returns { sessionReady = false, reason = 'no_key' }.
function ravensight.init(options)
  assert(type(options) == 'table', 'ravensight.init: pass a table of options')
  assert(options.ingestKey == nil or type(options.ingestKey) == 'string', 'ravensight.init: ingestKey must be a string')
  if initialized then
    log('warn', 'init() called twice; the second call is ignored')
    return
  end
  initialized = true
  config = {
    apiUrl = options.apiUrl or 'https://api.ravensight.io',
    ingestKey = options.ingestKey or '',
    gameVersion = options.gameVersion or '1.0.0',
    enabled = options.enabled ~= false,
    maxQueueSize = options.maxQueueSize or Core.DEFAULT_MAX_QUEUE_SIZE,
    flushInterval = options.flushInterval or Core.DEFAULT_FLUSH_INTERVAL_SECONDS,
    handleQuit = options.handleQuit ~= false,
    transport = options.transport,
    timeout = options.timeout or 15,
    debug = options.debug == true,
    synchronous = options.synchronous == true,
    optional = options.optional == true,
    consent = Core.normalizeConsent(options.consent),
    distribution = options.distribution,
  }
  -- Switched off by the game: no session, no queue, every call a no-op.
  if not config.enabled then
    log('info', 'disabled by the enabled option; nothing is sent this run')
    return
  end
  if config.transport == 'web' or systemName() == 'Web' then
    -- The page holds the key; the Lua side needs none.
    core = require(modulePrefix .. 'web').new({
      storage = storage, log = log, consent = config.consent, randomHex = randomHex,
    })
    transportName = 'web'
    core:start()
    return { sessionReady = false, reason = 'web_bridge' }
  end
  -- No key: a keyless clone or a development build. Inert, not an error:
  -- no files, no network, no thread, and every call a no-op.
  if config.ingestKey == '' then
    inert = true
    if not config.optional then
      log('warn', 'no ingestKey, so analytics is off for this run (pass optional = true to silence this line)')
    end
    return { sessionReady = false, reason = 'no_key' }
  end
  local platform, osName = platformNames()
  core = Core.new({
    apiUrl = config.apiUrl,
    ingestKey = config.ingestKey,
    gameVersion = config.gameVersion,
    maxQueueSize = config.maxQueueSize,
    flushInterval = config.flushInterval,
    send = send,
    now = love.timer and love.timer.getTime or os.clock,
    time = os.time,
    storage = storage,
    randomHex = randomHex,
    platform = platform,
    osName = osName,
    log = log,
    playtest = playtestFromEnvironment(),
    consent = config.consent,
    distribution = config.distribution,
    random = love.math and love.math.random or math.random,
  })
  startNetwork()
  core:start()
end

--- Delivers answers and runs the batching and retry timers. Call from
--- love.update(dt).
function ravensight.update()
  if not core or transportName == 'web' then return end
  pollResponses()
  core:update()
  if holdingQuit and core.quitReady then
    holdingQuit = false
    love.event.quit()
  end
end

--- Call as `function love.quit() return ravensight.quit() end`. The first
--- call records game_exited, starts the last flush and returns true, which
--- tells LÖVE to wait; the SDK quits again itself once the flush is answered
--- or 1.5 seconds pass. Returns false when there is nothing to wait for.
--- With handleQuit = false it records and flushes, and never delays.
function ravensight.quit()
  if not core or transportName == 'web' then return false end
  if core.quitReady then
    if requestChannel then requestChannel:push('stop') end
    return false
  end
  if not config.handleQuit then
    core:beginQuit()
    core:finishQuit()
    return false
  end
  local hold = core:beginQuit()
  holdingQuit = hold
  if not hold and requestChannel then requestChannel:push('stop') end
  return hold
end

--- Queue an event. data is a flat table of strings, numbers and booleans.
function ravensight.track(name, data)
  if core then core:track(name, data) end
end

--- Send what is queued now instead of waiting for the batching timer.
function ravensight.flush()
  if core then core:flush() end
end

--- Send player feedback. category (bug, suggestion, complaint, praise,
--- playtest or other) and rating (1 to 5) are optional. Returns true when it
--- was sent, or false and a reason ("invalid_category", "no_session", ...)
--- when it was refused before sending. The server's answer arrives on
--- "feedback_submitted" or "feedback_failed".
function ravensight.submitFeedback(message, category, rating)
  if not core then return false, 'not_started' end
  return core:submitFeedback(message, category, rating)
end

--- The player's choice, remembered across launches. Wire it to your own
--- consent or settings screen; Ravensight ships no consent UI. With
--- consent = "opt_in" it is the yes that starts everything. After
--- init({ enabled = false }), or an inert start with no key, the choice is
--- still saved, but it cannot turn the SDK on for this run.
function ravensight.setTrackingEnabled(enabled)
  if core then
    core:setTrackingEnabled(enabled)
  elseif initialized then
    Core.saveChoice(storage, config.consent, enabled and true or false)
  end
end

--- The player's choice. While collecting, true when events are collected.
--- After init({ enabled = false }) or an inert start, it reports the
--- player's saved choice, so a settings toggle still shows the right state.
function ravensight.isTrackingEnabled()
  if core then return core:isTrackingEnabled() end
  return initialized and Core.savedChoice(storage, config.consent)
end

--- True only when the SDK is running and collecting: a key (or the web
--- bridge), not switched off by enabled = false, the player, the server or a
--- refused key. Use it to skip work that only feeds analytics.
function ravensight.enabled()
  return core ~= nil and core:isTrackingEnabled() == true
end

--- Starts a fresh analytics identity for this install. In a web build the
--- page owns the id; call the JavaScript SDK there instead.
function ravensight.resetDeviceId()
  if not core then return end
  if transportName == 'web' then
    log('info', 'resetDeviceId() is handled by ravensight-js on the page in a web build')
    return
  end
  core:resetDeviceId()
end

--- This install's random device id. nil in a web build, where the page's
--- JavaScript SDK keeps it.
function ravensight.getDeviceId()
  return core and core.deviceId or nil
end

--- Which way requests are being sent ("https", "winhttp", "libcurl",
--- "curl", "web"), or nil before the worker has reported or when none works.
function ravensight.getTransport()
  return transportName
end

--- Subscribe to an SDK event; returns a function that unsubscribes. Events:
--- session_ready, session_failed(reason), tracking_disabled(source),
--- events_flushed(count), flush_failed(reason), feedback_submitted,
--- feedback_failed(reason), event_tracked(name, data).
function ravensight.on(name, fn)
  assert(initialized, 'ravensight.on: call ravensight.init() first')
  if not core then return function() end end
  return core:on(name, fn)
end

--- Switch into playtest mode by hand. Normally read from the environment.
function ravensight.setPlaytestContext(ctx)
  if core and core.setPlaytestContext then core:setPlaytestContext(ctx) end
end

return ravensight
