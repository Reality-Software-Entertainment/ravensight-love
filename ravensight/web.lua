-- ravensight/web.lua: the love.js (browser) path.
--
-- A game built with love.js runs inside a web page, where Lua has no way to
-- make an HTTPS request. So in a web build the SDK sends nothing itself. It
-- prints each call as one tagged line of JSON instead, and the page, which
-- runs the Ravensight JavaScript SDK (ravensight-js), turns those lines into
-- calls on it through web/ravensight-love-bridge.js:
--
--   __RAVENSIGHT__ {"v":1,"op":"track","event":"...","data":{...},"timestamp":<ms>}
--   __RAVENSIGHT__ {"v":1,"op":"feedback","message":"...","category":"...","rating":5}
--   __RAVENSIGHT__ {"v":1,"op":"enabled","value":false}
--   __RAVENSIGHT__ {"v":1,"op":"flush"}
--
-- The JavaScript SDK owns the session, the device id, batching and the two
-- lifecycle events (game_started and game_exited), so none of them happen
-- here. Keys come out sorted, since the SDK's JSON encoder sorts them.
--
-- MIT licensed, part of ravensight-love.

local prefix = (...):gsub('web$', '')
local json = require(prefix .. 'json')
local Core = require(prefix .. 'core')

local Web = {}
Web.__index = Web

Web.TAG = '__RAVENSIGHT__ '
Web.PROTOCOL_VERSION = 1

local EVENTS = {
  session_ready = true, session_failed = true, tracking_disabled = true,
  events_flushed = true, flush_failed = true, feedback_submitted = true,
  feedback_failed = true, event_tracked = true,
}

local function noop() end

--- deps:
---   print(line)                     where tagged lines go, default print
---   time()                          unix seconds, default os.time
---   storage                         {read(name), write(name, text), remove(name)}
---   log(level, message)             "info", "warn" or "error"
function Web.new(deps)
  deps = deps or {}
  local self = setmetatable({}, Web)
  self.print = deps.print or print
  self.time = deps.time or os.time
  self.storage = deps.storage or { read = noop, write = noop, remove = noop }
  self.log = deps.log or noop
  self.listeners = {}
  self.trackingEnabled = true
  return self
end

function Web:on(name, fn)
  assert(EVENTS[name], 'ravensight: unknown event "' .. tostring(name) .. '"')
  self.listeners[name] = self.listeners[name] or {}
  table.insert(self.listeners[name], fn)
  return function()
    for i, f in ipairs(self.listeners[name]) do
      if f == fn then table.remove(self.listeners[name], i) return end
    end
  end
end

function Web:emit(name, ...)
  for _, fn in ipairs(self.listeners[name] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then self.log('error', 'a ' .. name .. ' listener failed: ' .. tostring(err)) end
  end
end

--- Prints one operation as a single tagged line.
function Web:send(message)
  message.v = Web.PROTOCOL_VERSION
  self.print(Web.TAG .. json.encode(message))
end

--- Reads the player's saved opt-out and, if there is one, tells the page.
function Web:start()
  self.log('info', 'transport web (bridge to ravensight-js)')
  if self.storage.read(Core.OPTOUT_FILE) ~= nil then
    self.trackingEnabled = false
    self:send({ op = 'enabled', value = false })
  end
end

function Web:track(name, data)
  if not self.trackingEnabled then return end
  assert(type(name) == 'string' and name ~= '', 'ravensight.track: the event name must be a non-empty string')
  if data ~= nil and type(data) ~= 'table' then
    error('ravensight.track: data must be a table or nil', 2)
  end
  data = data or {}
  self:send({ op = 'track', event = name, data = data, timestamp = self.time() * 1000 })
  self:emit('event_tracked', name, data)
end

function Web:flush()
  if not self.trackingEnabled then return end
  self:send({ op = 'flush' })
end

--- Same checks as on the desktop. Returns true when the line was printed;
--- whether the server accepted it is up to the page's SDK.
function Web:submitFeedback(message, category, rating)
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
  local payload = { op = 'feedback', message = message }
  if category and category ~= '' then payload.category = category end
  if type(rating) == 'number' and rating > 0 then payload.rating = math.floor(rating) end
  self:send(payload)
  return true
end

--- The player's opt-out, saved like on the desktop and passed to the page.
function Web:setTrackingEnabled(enabled)
  enabled = enabled and true or false
  if enabled == self.trackingEnabled then return end
  self.trackingEnabled = enabled
  if enabled then
    self.storage.remove(Core.OPTOUT_FILE)
  else
    self.storage.write(Core.OPTOUT_FILE, '1')
  end
  self:send({ op = 'enabled', value = enabled })
  if not enabled then
    self.log('info', 'tracking disabled by player opt-out')
    self:emit('tracking_disabled', 'player')
  end
end

function Web:isTrackingEnabled()
  return self.trackingEnabled
end

return Web
