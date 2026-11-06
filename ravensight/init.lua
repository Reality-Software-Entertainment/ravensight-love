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
local Typed = require(modulePrefix .. 'typed')
local Errors = require(modulePrefix .. 'errors')

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
local health        -- the performance sampler, only with performance = true
local capture       -- automatic error capture (ravensight/errors.lua), once installed
local held = {}     -- boot errors captured before the first session answer
local MAX_HELD = 5
--- Crashes captured before the session answer, saved so the next launch can
--- send them once its answer says capture is on, or discard them if off.
local CRASH_FILE = 'ravensight_crash.json'
local sdkPrinting = false -- true while the SDK prints its own line

local SDK_LINE = 'Ravensight: '
local WEB_TAG = '__RAVENSIGHT__ '

local function log(level, message)
  if level == 'info' and not (config and config.debug) then return end
  sdkPrinting = true
  local ok, err = pcall(print, SDK_LINE .. message)
  sdkPrinting = false
  if not ok then error(err, 0) end
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

--- Creates the folder a file goes in, in the save folder. Always asked,
--- never checked first: getInfo also sees the game's own files, and the
--- SDK's module folder is called ravensight too.
local function ensureFolder(name)
  local folder = name:match('^(.*)/[^/]+$')
  if folder and love.filesystem.createDirectory then love.filesystem.createDirectory(folder) end
end

--- Renames `from` over `to` (real paths), replacing it. POSIX rename does
--- that in one step; on Windows MoveFileExW with MOVEFILE_REPLACE_EXISTING
--- does, given UTF-16 paths.
local function renameOver(from, to)
  local okFfi, ffi = pcall(require, 'ffi')
  if okFfi and ffi.os == 'Windows' then
    pcall(ffi.cdef, [[
      int MultiByteToWideChar(unsigned int, unsigned long, const char*, int, wchar_t*, int);
      int MoveFileExW(const wchar_t*, const wchar_t*, unsigned long);
    ]])
    local function wide(text)
      local n = ffi.C.MultiByteToWideChar(65001, 0, text, -1, nil, 0)
      if n <= 0 then return nil end
      local buf = ffi.new('wchar_t[?]', n)
      ffi.C.MultiByteToWideChar(65001, 0, text, -1, buf, n)
      return buf
    end
    local a, b = wide(from), wide(to)
    local okLib, kernel = pcall(ffi.load, 'kernel32')
    if not (a and b and okLib) then return false end
    -- MOVEFILE_REPLACE_EXISTING (1) | MOVEFILE_WRITE_THROUGH (8)
    return kernel.MoveFileExW(a, b, 9) ~= 0
  end
  return os.rename(from, to) == true
end

--- Keeps a file out of backups where the system has a way to say so. On
--- macOS that is the extended attribute `tmutil addexclusion` writes (its
--- value is the binary property list of the string "com.apple.backupd").
--- Returns true when it was set. Android and iOS builds need the game's own
--- backup rules (see the README); other desktops have no common mechanism.
local BACKUP_EXCLUDE_NAME = 'com.apple.metadata:com_apple_backup_excludeItem'
local BACKUP_EXCLUDE_VALUE = '\98\112\108\105\115\116\48\48\95\16\17' .. 'com.apple.backupd'
  .. '\8\0\0\0\0\0\0\1\1\0\0\0\0\0\0\0\1\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\28'
function ravensight._excludeFromBackup(path)
  local okFfi, ffi = pcall(require, 'ffi')
  if not okFfi or ffi.os ~= 'OSX' then return false end
  pcall(ffi.cdef, 'int setxattr(const char*, const char*, const void*, size_t, uint32_t, int);')
  local ok, result = pcall(ffi.C.setxattr, path, BACKUP_EXCLUDE_NAME, BACKUP_EXCLUDE_VALUE, #BACKUP_EXCLUDE_VALUE, 0, 0)
  return ok and result == 0
end

local storage = {
  read = function(name)
    if not love.filesystem.getInfo(name) then return nil end
    return love.filesystem.read(name)
  end,
  write = function(name, text)
    ensureFolder(name)
    love.filesystem.write(name, text)
  end,
  remove = function(name) love.filesystem.remove(name) end,
  --- Writes a temporary file and renames it over `name`, so a partial
  --- write never replaces a good file. Where a rename is not possible (no
  --- real save folder) it writes the file directly.
  replace = function(name, text)
    ensureFolder(name)
    local tmp = name .. '.tmp'
    local dir = love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()
    if dir and dir ~= '' and love.filesystem.write(tmp, text) then
      -- The queue holds origin stamps and scrubbed captures: keep it out of
      -- backups. Set on the new file, so the rename carries it over.
      ravensight._excludeFromBackup(dir .. '/' .. tmp)
      if renameOver(dir .. '/' .. tmp, dir .. '/' .. name) then return true end
      love.filesystem.remove(tmp)
    end
    return love.filesystem.write(name, text)
  end,
}

--- gzip, SHA-256 and the GPU name from LÖVE where it has them.
local function gzipFunction()
  if not (love.data and love.data.compress) then return nil end
  return function(text) return love.data.compress('string', 'gzip', text) end
end

local function sha256Function()
  if not (love.data and love.data.hash) then return nil end
  return function(bytes) return love.data.hash('sha256', bytes) end
end

local function deviceFields()
  local fields = {}
  if love.graphics and love.graphics.getRendererInfo then
    local ok, _, _, _, device = pcall(love.graphics.getRendererInfo)
    if ok and type(device) == 'string' then fields.gpu = device end
  end
  return fields
end

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

local boundedTransport
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
    local selected = syncTransport
    if req.maxResponseBytes then
      boundedTransport = boundedTransport or require(modulePrefix .. 'transport').select(nil, true)
      selected = boundedTransport
    end
    local status, body, headers = 0, 'no_bounded_transport', {}
    if selected then status, body, headers = selected.request(req) end
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

-- ------------------------------------------------------- error capture
--
-- Installed once, and only when everything allows it: a key (or the web
-- bridge), the player's consent and the errorCapture option not false.
-- Fetching settings installs nothing. Errors captured before the first
-- session answer (boot errors) are held in memory, at most 5; the answer
-- sends them when its errorCapture.enabled is not false and discards them
-- unsent otherwise. Every hook chains to what was there before; a failure
-- inside capture is dropped silently.

--- The words print would write for these arguments, tab separated.
local function printed(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
  return table.concat(parts, '\t')
end

--- The desktop crash, queued behind gameplay and saved to the save
--- directory at once, so the next launch sends it if this process dies
--- before the flush is answered.
local function captureCrash(msg, stack)
  if not capture or not core then return end
  if transportName == 'web' then
    if not core.trackingEnabled then return end
    local data = capture:capture({ source = 'crash', severity = 'critical', message = tostring(msg), stack = stack })
    if data then core:track('error', data) end
    return
  end
  if not core.trackingEnabled then return end
  if not core.sessionAnswered then
    -- A crash before the session answer: the switch is not known, so no
    -- trail. Held, and saved to the crash file before the handler returns
    -- (never in a playtest run, whose events are never carried over).
    if #held >= MAX_HELD then return end
    local data = capture:capture({ source = 'crash', severity = 'critical', message = tostring(msg), stack = stack })
    if not data then return end
    held[#held + 1] = { data = data, timestamp = os.time() }
    if core.playtestToken == '' then storage.write(CRASH_FILE, json.encode(held)) end
    return
  end
  if not core:errorCaptureAllowed() then return end
  local data = capture:capture({
    source = 'crash', severity = 'critical', message = tostring(msg), stack = stack,
    trail = core.errorTrailEnabled,
  })
  if not data or not core:enqueueError('error', data) then return end
  core:saveQueue()
  -- With the worker thread this only hands the batch over; the synchronous
  -- transport would block the error screen, so it waits for the next launch.
  if requestChannel then core:flush() end
end

--- On a session answer: held boot errors are sent when capture is on, and
--- discarded unsent when it is off. The trail goes only with the trail on.
local function releaseHeld()
  if #held == 0 or not core then return end
  local list = held
  held = {}
  if core:errorCaptureAllowed() then
    for _, entry in ipairs(list) do
      local queued = core:enqueueError('error', entry.data)
      -- Keep the time of the crash, not of this send.
      if queued and type(entry.timestamp) == 'number' then
        -- Held in unix seconds; the queue keeps milliseconds.
        local ms = entry.timestamp < 1e12 and entry.timestamp * 1000 or entry.timestamp
        for _, e in ipairs(core.pending) do
          if e.data == queued then e.timestamp = ms end
        end
      end
    end
    core:saveQueue()
  end
  -- Sent (now in the saved queue) or discarded: either way the file goes.
  storage.remove(CRASH_FILE)
end

--- A crash file from an earlier launch: held until this launch's answer.
local function loadCrashFile()
  local ok, text = pcall(storage.read, CRASH_FILE)
  local saved = ok and type(text) == 'string' and #text <= 65536 and json.decode(text) or nil
  if type(saved) ~= 'table' then
    if text then storage.remove(CRASH_FILE) end
    return
  end
  -- At most 5, at most 30 days old; older ones are deleted unsent.
  local oldest = os.time() - Errors.PENDING_MAX_AGE
  for _, entry in ipairs(saved) do
    if #held >= MAX_HELD then break end
    if type(entry) == 'table' and type(entry.data) == 'table' and Errors.isAutomatic(entry.data)
      and type(entry.timestamp) == 'number' and entry.timestamp >= oldest then
      entry.data.rs_trail = nil
      held[#held + 1] = { data = entry.data, timestamp = entry.timestamp }
    end
  end
  if #held == 0 then storage.remove(CRASH_FILE) end
end

local afterCrashSaved
--- Runs while the error screen shows: delivers answers and keeps the saved
--- queue in step, so a crash that was sent is not sent again next launch.
local function pumpAfterCrash()
  pollResponses()
  core:update()
  if #core.pending ~= afterCrashSaved then
    afterCrashSaved = #core.pending
    core:saveQueue()
  end
end

local function installErrorHandler()
  if not love then return end
  local previous = love.errorhandler or love.errhand
  if type(previous) ~= 'function' then return end
  love.errorhandler = function(msg, ...)
    local stack = Errors.stackOf(debug.traceback('', 2))
    pcall(captureCrash, msg, stack)
    afterCrashSaved = core and core.pending and #core.pending or 0
    local loop = previous(msg, ...)
    -- With no worker thread every request blocks the frame it is sent from,
    -- so the error screen sends nothing: the saved crash goes next launch.
    if type(loop) ~= 'function' or transportName == 'web' or not core or not requestChannel then return loop end
    return function(...)
      pcall(pumpAfterCrash)
      local result = loop(...)
      if result ~= nil then pcall(core.saveQueue, core) end
      return result
    end
  end
end

local function recordPrint(...)
  if transportName == 'web' or not core.trackingEnabled then return end
  -- Before the session answer the switch is unknown: the ring (memory only)
  -- keeps the lines, and they leave only if the answer turns the trail on.
  if core.sessionAnswered and not (core.errorTrailEnabled and core:errorCaptureAllowed()) then return end
  local line = printed(...)
  if line:sub(1, #SDK_LINE) == SDK_LINE or line:sub(1, #WEB_TAG) == WEB_TAG then return end
  capture:record('info', line)
end

local function installPrintHook()
  local previous = print
  if type(previous) ~= 'function' then return end
  _G.print = function(...)
    if not sdkPrinting and capture and core then pcall(recordPrint, ...) end
    return previous(...)
  end
end

--- Installs capture once, when the gate allows it.
local function installCapture()
  if capture or not config or not core then return end
  if config.errorCapture == false then
    if transportName ~= 'web' then storage.remove(CRASH_FILE) end
    return
  end
  if not core.trackingEnabled or core.keyRefused then return end
  capture = Errors.new({ now = love.timer and love.timer.getTime or os.clock })
  if transportName ~= 'web' and core.playtestToken == '' then loadCrashFile() end
  installErrorHandler()
  -- The web build has no trail: the page's SDK owns the session answer, so
  -- the Lua side never learns the trail switch.
  if transportName ~= 'web' then installPrintHook() end
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
---   performance   sample the frame rate once a second and send one `health`
---                 event per session, on quit (desktop) or before the page
---                 hides (web), default false. See "Typed events" in the README.
---   errorCapture  false turns automatic error capture off for this build,
---                 default true. See "Error capture" in the README.
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
    performance = options.performance == true,
    errorCapture = options.errorCapture ~= false,
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
    installCapture()
    if config.performance then health = Typed.Health.new({ random = love.math and love.math.random or math.random }) end
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
    gzip = gzipFunction(),
    sha256 = sha256Function(),
    device = deviceFields(),
  })
  startNetwork()
  -- The session answer carries the game's switch: it releases or discards
  -- the boot errors held until then.
  core:on('session_ready', function() pcall(releaseHeld) end)
  core:start()
  installCapture()
  if config.performance then
    health = Typed.Health.new({
      random = love.math and love.math.random or math.random,
      memoryMb = function() return collectgarbage('count') / 1024 end,
      -- CPU seconds since the process began, a stand-in for the wall time
      -- LÖVE does not expose; it covers loading and require()s.
      bootMs = os.clock() * 1000,
    })
  end
end

--- Delivers answers and runs the batching and retry timers. Call from
--- love.update(dt). Pass dt so performance sampling can use it; the
--- no-argument form still works (it falls back to love.timer.getDelta).
function ravensight.update(dt)
  if not core then return end
  if health then
    if dt == nil and love.timer and love.timer.getDelta then dt = love.timer.getDelta() end
    if health:tick(dt) and transportName == 'web' and (health.seen == 3 or health.seen % 10 == 0) then
      -- Lua cannot run when the page hides, so the page keeps the latest
      -- summary and the bridge sends it once, before the page goes.
      local summary = health:summary()
      if summary then core:stashHealth(summary) end
    end
  end
  if transportName == 'web' then core:update() return end
  pollResponses()
  core:update()
  if holdingQuit and core.quitReady then
    holdingQuit = false
    love.event.quit()
  end
end

--- Sends the one health event of the session, if sampling is on and any
--- second was sampled. Desktop only: the web path goes through the bridge.
local function sendHealth()
  if not health or health.sent or transportName == 'web' then return end
  local summary = health:summary()
  if not summary then return end
  health.sent = true
  core:track('health', summary)
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
  sendHealth()
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

-- Typed events: each builds the reserved rs_* properties (ravensight/typed.lua)
-- and calls track, so it returns what track returns and never throws on bad
-- values. opts.props is a map of extra properties, merged first so the
-- reserved keys win; opts.name replaces the default event name.

--- A real-money purchase. amount is an integer in minor units (499 is 4.99)
--- or a digit string; currency is a 3 letter code, upper-cased for you.
--- opts: cart, transactionId, name, props.
function ravensight.purchase(amount, currency, itemType, itemId, opts)
  local name, props = Typed.purchase(amount, currency, itemType, itemId, opts)
  return ravensight.track(name, props)
end

--- A resource entering ("source") or leaving ("sink") the economy.
--- opts: itemType, itemId, name, props.
function ravensight.resource(flow, resource, amount, opts)
  local name, props = Typed.resource(flow, resource, amount, opts)
  return ravensight.track(name, props)
end

--- A progression step: status "start", "complete" or "fail", p1 the level
--- or node. opts: p2, p3, score, name, props.
function ravensight.progression(status, p1, opts)
  local name, props = Typed.progression(status, p1, opts)
  return ravensight.track(name, props)
end

--- An error. severity is "debug", "info", "warning", "error" or "critical";
--- message is cut to 200 characters. opts: stack (cut to 2000), name, props.
function ravensight.error(severity, message, opts)
  local name, props = Typed.error(severity, message, opts)
  return ravensight.track(name, props)
end

--- Send what is queued now instead of waiting for the batching timer.
function ravensight.fetchConfig()
  return core and core:fetchConfig() or false
end
function ravensight.getConfig(key, fallback)
  if not core then return fallback end
  return core:getConfig(key, fallback)
end

function ravensight.flush()
  if core then core:flush() end
end

-- Reports are native-only: a web game must use ravensight-js on its page.
local reportClient, reportCore
function ravensight.createReport(input)
  if not core then return nil, 'not_started' end
  if transportName == 'web' then return nil, 'use_javascript_reports' end
  if reportCore ~= core then
    reportCore = core
    reportClient = require(modulePrefix .. 'reports').new(core, function(png)
      return love.data.encode('string', 'hex', love.data.hash('sha256', png))
    end)
  end
  return reportClient.prepare(input)
end
function ravensight.submitReport(report, callback)
  if not core or reportCore ~= core or not reportClient then return false, 'not_started' end
  return reportClient.submit(report, callback)
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
    if enabled then
      installCapture()
    else
      held = {}
      if transportName ~= 'web' then storage.remove(CRASH_FILE) end
    end
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
  held = {}
  storage.remove(CRASH_FILE)
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

-- ------------------------------------------------------ ads and attribution

--- An ad lifecycle step (see Typed.ad). Returns true when queued, or false
--- and the reason it was refused; nothing malformed is sent.
function ravensight.trackAd(network, format, result, opts)
  local name, props = Typed.ad(network, format, result, opts)
  if not name then
    log('warn', 'ad event not sent: ' .. props)
    return false, props
  end
  ravensight.track(name, props)
  return true
end

--- A paid impression: trackAd with result "shown". revenueMicros is a digit
--- string of micros (0.0015 USD is "1500"), never a float.
function ravensight.trackAdRevenue(network, format, placement, revenueMicros, currency, opts)
  local merged = {}
  for k, v in pairs(opts or {}) do merged[k] = v end
  merged.placement, merged.revenueMicros, merged.currency = placement, revenueMicros, currency
  return ravensight.trackAd(network, format, 'shown', merged)
end

ravensight.microsFromDecimalString = Typed.microsFromDecimalString
ravensight.microsFromRevenue = Typed.microsFromRevenue

--- Where this install was acquired, sent once per install. Returns true
--- when queued, or false and why.
function ravensight.setAttribution(attribution)
  if not core or not core.setAttribution then return false, 'not_started' end
  return core:setAttribution(attribution)
end

--- Events let go of since launch: dropped_overflow, dropped_too_old and
--- dropped_refused. Empty in a web build, where the page delivers.
function ravensight.getDeliveryStats()
  if core and core.getDeliveryStats then return core:getDeliveryStats() end
  return {}
end

--- Switch into playtest mode by hand. Normally read from the environment.
function ravensight.setPlaytestContext(ctx)
  if core and core.setPlaytestContext then core:setPlaytestContext(ctx) end
end

return ravensight
