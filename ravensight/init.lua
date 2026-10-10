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
-- Works on LÖVE 11.x and 12.x, desktop (Windows, macOS, Linux). See
-- README.md for the full reference and https://ravensight.io/docs/#love-sdk.
--
-- MIT licensed, part of ravensight-love.

local modulePrefix = (...):gsub('init$', ''):gsub('%.?$', '.')
if modulePrefix == '.' then modulePrefix = '' end

local Core = require(modulePrefix .. 'core')
local json = require(modulePrefix .. 'json')

local ravensight = { VERSION = Core.VERSION }

local core
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

local function platformNames()
  local os = love.system and love.system.getOS() or 'unknown'
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
---   apiUrl        "https://api.ravensight.io" (no trailing slash, no /api/v1)
---   ingestKey     your game's publishable gt_live_ key
---   gameVersion   reported with every session, default "1.0.0"
---   maxQueueSize  unsent events kept, oldest dropped first, default 100
---   handleQuit    hold the quit for up to 1.5 s to send the last events,
---                 default true (needs love.quit to return ravensight.quit())
---   transport     "https", "winhttp", "libcurl" or "curl" to try first
---   timeout       seconds per request, default 15
---   debug         print informational messages too, default false
function ravensight.init(options)
  assert(type(options) == 'table', 'ravensight.init: pass a table of options')
  assert(type(options.ingestKey) == 'string' and options.ingestKey ~= '', 'ravensight.init: ingestKey is required')
  if core then
    log('warn', 'init() called twice; the second call is ignored')
    return
  end
  config = {
    apiUrl = options.apiUrl or 'https://api.ravensight.io',
    ingestKey = options.ingestKey,
    gameVersion = options.gameVersion or '1.0.0',
    maxQueueSize = options.maxQueueSize or 100,
    handleQuit = options.handleQuit ~= false,
    transport = options.transport,
    timeout = options.timeout or 15,
    debug = options.debug == true,
    synchronous = options.synchronous == true,
  }
  local platform, osName = platformNames()
  core = Core.new({
    apiUrl = config.apiUrl,
    ingestKey = config.ingestKey,
    gameVersion = config.gameVersion,
    maxQueueSize = config.maxQueueSize,
    send = send,
    now = love.timer and love.timer.getTime or os.clock,
    time = os.time,
    storage = storage,
    randomHex = randomHex,
    platform = platform,
    osName = osName,
    log = log,
    playtest = playtestFromEnvironment(),
  })
  startNetwork()
  core:start()
end

--- Delivers answers and runs the retry timer. Call from love.update().
function ravensight.update()
  if not core then return end
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
  if not core then return false end
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

--- Send what is queued now instead of on the next event.
function ravensight.flush()
  if core then core:flush() end
end

--- Send player feedback. category and rating (1 to 5) are optional. The
--- answer arrives on "feedback_submitted" or "feedback_failed".
function ravensight.submitFeedback(message, category, rating)
  if core then core:submitFeedback(message, category, rating) end
end

--- Player opt-out, remembered across launches. Wire it to your own consent
--- or settings screen; Ravensight ships no consent UI.
function ravensight.setTrackingEnabled(enabled)
  if core then core:setTrackingEnabled(enabled) end
end

--- True while events are being collected.
function ravensight.isTrackingEnabled()
  return core ~= nil and core:isTrackingEnabled()
end

--- Starts a fresh analytics identity for this install.
function ravensight.resetDeviceId()
  if core then core:resetDeviceId() end
end

--- This install's random device id.
function ravensight.getDeviceId()
  return core and core.deviceId or nil
end

--- Which way requests are being sent ("https", "winhttp", "libcurl",
--- "curl"), or nil before the worker has reported or when none works.
function ravensight.getTransport()
  return transportName
end

--- Subscribe to an SDK event; returns a function that unsubscribes. Events:
--- session_ready, session_failed(reason), tracking_disabled(source),
--- events_flushed(count), flush_failed(reason), feedback_submitted,
--- feedback_failed(reason), event_tracked(name, data).
function ravensight.on(name, fn)
  assert(core, 'ravensight.on: call ravensight.init() first')
  return core:on(name, fn)
end

--- Switch into playtest mode by hand. Normally read from the environment.
function ravensight.setPlaytestContext(ctx)
  if core then core:setPlaytestContext(ctx) end
end

return ravensight
