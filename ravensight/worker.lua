-- ravensight/worker.lua: the body of the SDK's love.thread.
--
-- Requests arrive on one channel as JSON strings and answers go back on
-- another, so a slow network never costs your game a frame. The thread picks
-- a transport once (see ravensight/transport.lua) and reports which one, or
-- that none works, before it answers anything else.
--
-- MIT licensed, part of ravensight-love.

local modulePrefix, requestChannelName, responseChannelName, prefer = ...

-- A thread starts with an empty Lua state. love.filesystem is what lets
-- require() find modules inside the game's own files.
require('love.filesystem')
local json = require(modulePrefix .. 'json')
local transport = require(modulePrefix .. 'transport')

local requests = love.thread.getChannel(requestChannelName)
local responses = love.thread.getChannel(responseChannelName)

local chosen = transport.select(prefer ~= '' and prefer or nil)
responses:push(json.encode({ kind = 'ready', transport = chosen and chosen.name or json.null }))

while true do
  local message = requests:demand()
  if message == 'stop' then break end
  local req = json.decode(message)
  if req then
    local status, body, headers
    if chosen then
      local ok, s, b, h = pcall(chosen.request, req)
      if ok then status, body, headers = s, b, h else status, body, headers = 0, tostring(s), {} end
    else
      status, body, headers = 0, 'no_transport', {}
    end
    responses:push(json.encode({ kind = 'response', id = req.id, status = status, body = body or '', headers = headers or {} }))
  end
end
