-- ravensight/init.lua against a fake `love`: the enabled option and the
-- love.js web bridge. Neither touches the network, so no transport is needed.

local json = require('ravensight.json')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

--- A fresh copy of the SDK on a fake LÖVE, with print captured.
local function boot(os, files)
  for name in pairs(package.loaded) do
    if name == 'ravensight' or name:match('^ravensight%.') then package.loaded[name] = nil end
  end
  local w = { files = files or {}, lines = {} }
  _G.love = {
    system = { getOS = function() return os or 'OS X' end },
    filesystem = {
      getInfo = function(n) return w.files[n] and {} or nil end,
      read = function(n) return w.files[n] end,
      write = function(n, t) w.files[n] = t end,
      remove = function(n) w.files[n] = nil end,
    },
    timer = { getTime = function() return 0 end },
  }
  w.realPrint = print
  _G.print = function(line) table.insert(w.lines, line) end
  w.sdk = require('ravensight')
  function w.done()
    _G.print = w.realPrint
    _G.love = nil
  end
  --- The tagged lines, decoded.
  function w.ops()
    local out = {}
    for _, line in ipairs(w.lines) do
      local text = line:match('^__RAVENSIGHT__ (.*)$')
      if text then out[#out + 1] = json.decode(text) end
    end
    return out
  end
  return w
end

local function run(os, files, fn)
  local w = boot(os, files)
  local ok, err = pcall(fn, w)
  w.done()
  if not ok then error(err, 0) end
end

return {
  { 'love.js is detected from the OS and init returns at once', function()
    run('Web', nil, function(w)
      local result = w.sdk.init({ ingestKey = 'gt_live_k', debug = true })
      eq(result.sessionReady, false); eq(result.reason, 'web_bridge')
      eq(w.sdk.getTransport(), 'web')
      eq(w.lines[1], 'Ravensight: transport web (bridge to ravensight-js)')
      eq(#w.ops(), 0, 'no game_started from Lua in a web build')
    end)
  end },
  { 'web track prints one tagged JSON line', function()
    run(nil, nil, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k', transport = 'web' })
      w.sdk.track('level_start', { level = 'forest_1', n = 2 })
      eq(#w.lines, 1)
      assert(w.lines[1]:sub(1, 15) == '__RAVENSIGHT__ ', w.lines[1])
      assert(not w.lines[1]:find('\n'), 'one line')
      local op = w.ops()[1]
      eq(op.v, 1); eq(op.op, 'track'); eq(op.event, 'level_start')
      eq(op.data.level, 'forest_1'); eq(op.data.n, 2)
      eq(type(op.timestamp), 'number')
      assert(op.timestamp > 1e12, 'timestamp is in milliseconds')
    end)
  end },
  { 'web feedback prints a line, and a bad category prints none', function()
    run('Web', nil, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k' })
      eq(w.sdk.submitFeedback('too hard', 'suggestion', 5), true)
      local op = w.ops()[1]
      eq(op.op, 'feedback'); eq(op.message, 'too hard'); eq(op.category, 'suggestion'); eq(op.rating, 5)
      local ok, reason = w.sdk.submitFeedback('too hard', 'example', 5)
      eq(ok, false); eq(reason, 'invalid_category')
      eq(#w.ops(), 1)
      eq(w.lines[#w.lines], 'Ravensight: feedback_rejected invalid_category example')
    end)
  end },
  { 'web opt-out prints enabled false, is saved, and stops tracking', function()
    run('Web', nil, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k' })
      w.sdk.setTrackingEnabled(false)
      local op = w.ops()[1]
      eq(op.op, 'enabled'); eq(op.value, false)
      eq(w.sdk.isTrackingEnabled(), false)
      w.sdk.track('ignored', {})
      eq(#w.ops(), 1)
      assert(w.files.ravensight_optout, 'the opt-out is saved')
      w.sdk.setTrackingEnabled(true)
      eq(w.ops()[2].op, 'enabled'); eq(w.ops()[2].value, true)
    end)
  end },
  { 'a saved web opt-out is passed to the page at start', function()
    run('Web', { ravensight_optout = '1' }, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k' })
      eq(w.ops()[1].op, 'enabled'); eq(w.ops()[1].value, false)
    end)
  end },
  { 'web update, flush and quit never error, and flush prints its line', function()
    run('Web', nil, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k' })
      w.sdk.update(0.016)
      w.sdk.flush()
      eq(w.lines[#w.lines], '__RAVENSIGHT__ {"op":"flush","v":1}')
      w.sdk.setTrackingEnabled(false)
      local before = #w.lines
      w.sdk.flush()
      eq(#w.lines, before, 'flush is silent while opted out')
      eq(w.sdk.quit(), false)
      eq(#w.ops(), 2, 'quit sends no game_exited from Lua (flush, then enabled)')
    end)
  end },
  { 'enabled = false in a web build returns nil and prints nothing', function()
    run('Web', nil, function(w)
      eq(w.sdk.init({ ingestKey = 'gt_live_k', enabled = false }), nil)
      w.sdk.track('e', {})
      w.sdk.flush()
      eq(#w.lines, 0)
    end)
  end },
  { 'enabled = false: no session, no queue, every call a silent no-op', function()
    run(nil, nil, function(w)
      eq(w.sdk.init({ ingestKey = 'gt_live_k', enabled = false }), nil)
      w.sdk.update(1)
      w.sdk.track('e', {})
      w.sdk.flush()
      local stop = w.sdk.on('session_ready', function() end)
      stop()
      eq(w.sdk.submitFeedback('hi'), false)
      w.sdk.setTrackingEnabled(true)
      eq(w.sdk.isTrackingEnabled(), false, 'setTrackingEnabled(true) does not override enabled = false')
      eq(w.sdk.getDeviceId(), nil)
      eq(w.sdk.quit(), false)
      eq(#w.lines, 0, 'silent')
      eq(next(w.files), nil, 'nothing saved, not even a device id')
    end)
  end },
}
