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
  -- Counts the tagged lines init printed, so w.after() can check them.
  local realInit = w.sdk.init
  w.sdk.init = function(...)
    local result = realInit(...)
    w.startOps = #w.ops()
    return result
  end
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
  --- The tagged lines after init. With no argument, asserts init printed
  --- none (opt_out with no saved choice); with true or false, asserts it
  --- printed exactly one `enabled` line with that value, and skips it.
  function w.after(startValue)
    local ops = w.ops()
    if startValue == nil then
      eq(w.startOps or 0, 0, 'no start line without a saved choice')
    else
      eq(w.startOps, 1, 'one start line')
      eq(ops[1].op, 'enabled'); eq(ops[1].value, startValue)
      table.remove(ops, 1)
    end
    return ops
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
      eq(#w.lines, 1, 'no start line: no saved choice, so the page decides')
      eq(#w.after(), 0, 'no game_started from Lua in a web build')
    end)
  end },
  { 'web track prints one tagged JSON line', function()
    run(nil, nil, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k', transport = 'web' })
      w.sdk.track('level_start', { level = 'forest_1', n = 2 })
      eq(#w.lines, 1)
      assert(w.lines[1]:sub(1, 15) == '__RAVENSIGHT__ ', w.lines[1])
      assert(not w.lines[1]:find('\n'), 'one line')
      local op = w.after()[1]
      eq(op.v, 1); eq(op.op, 'track'); eq(op.event, 'level_start')
      eq(op.data.level, 'forest_1'); eq(op.data.n, 2)
      assert(op.data.rs_event_id:match('^%x+%-%x+%-%x%x%x%x%-1$'), op.data.rs_event_id)
      eq(type(op.timestamp), 'number')
      assert(op.timestamp > 1e12, 'timestamp is in milliseconds')
    end)
  end },
  { 'web feedback prints a line, and a bad category prints none', function()
    run('Web', nil, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k' })
      eq(w.sdk.submitFeedback('too hard', 'suggestion', 5), true)
      local op = w.after()[1]
      eq(op.op, 'feedback'); eq(op.message, 'too hard'); eq(op.category, 'suggestion'); eq(op.rating, 5)
      local ok, reason = w.sdk.submitFeedback('too hard', 'example', 5)
      eq(ok, false); eq(reason, 'invalid_category')
      eq(#w.after(), 1)
      eq(w.lines[#w.lines], 'Ravensight: feedback_rejected invalid_category example')
    end)
  end },
  { 'web opt-out prints enabled false, is saved, and stops tracking', function()
    run('Web', nil, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k' })
      w.sdk.setTrackingEnabled(false)
      local op = w.after()[1]
      eq(op.op, 'enabled'); eq(op.value, false)
      eq(w.sdk.isTrackingEnabled(), false)
      w.sdk.track('ignored', {})
      eq(#w.after(), 1)
      assert(w.files.ravensight_optout, 'the opt-out is saved')
      w.sdk.setTrackingEnabled(true)
      eq(w.after()[2].op, 'enabled'); eq(w.after()[2].value, true)
    end)
  end },
  { 'a saved web opt-out is passed to the page at start', function()
    run('Web', { ravensight_optout = '1' }, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k' })
      eq(#w.after(false), 0)
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
      eq(#w.after(), 2, 'quit sends no game_exited from Lua (flush, then enabled)')
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
      eq(w.sdk.getDeviceId(), nil)
      eq(w.sdk.quit(), false)
      eq(#w.lines, 0, 'silent')
      eq(next(w.files), nil, 'nothing saved, not even a device id')
    end)
  end },
  { 'enabled = false still saves the player opt-out, and the next launch honours it', function()
    local files = {}
    run(nil, files, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k', enabled = false })
      eq(w.sdk.isTrackingEnabled(), true, 'reports the saved choice: not opted out')
      w.sdk.setTrackingEnabled(false)
      eq(files.ravensight_optout, '1')
      eq(w.sdk.isTrackingEnabled(), false)
      eq(#w.lines, 0, 'still sends and prints nothing')
    end)
    run('Web', files, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k' })
      eq(w.sdk.isTrackingEnabled(), false)
      eq(w.ops()[1].op, 'enabled'); eq(w.ops()[1].value, false)
    end)
    run(nil, files, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k', enabled = false })
      w.sdk.setTrackingEnabled(true)
      eq(files.ravensight_optout, nil)
      eq(w.sdk.isTrackingEnabled(), true)
    end)
  end },
  { 'web feedback refuses a rating outside 1 to 5 or not whole', function()
    run('Web', nil, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k' })
      for _, bad in ipairs({ 0, 6, 2.5, -1, 'five' }) do
        local ok, reason = w.sdk.submitFeedback('hi', 'other', bad)
        eq(ok, false, tostring(bad)); eq(reason, 'invalid_rating', tostring(bad))
      end
      eq(#w.after(), 0)
      eq(w.lines[#w.lines], 'Ravensight: feedback_rejected invalid_rating five')
      eq(w.sdk.submitFeedback('hi', 'other', 1), true)
      eq(w.after()[1].rating, 1)
    end)
  end },

  -- --------------------------------------------- 0.3.0: inert with no key

  { 'no key on the desktop is inert: no files, no network, one warning', function()
    for _, key in ipairs({ false, '' }) do
      run(nil, nil, function(w)
        local selected = false
        package.loaded['ravensight.transport'] = { select = function() selected = true end }
        local result = w.sdk.init({ ingestKey = key or nil, gameVersion = '1.0.0' })
        eq(result.sessionReady, false); eq(result.reason, 'no_key')
        eq(#w.lines, 1)
        assert(w.lines[1]:find('no ingestKey', 1, true), w.lines[1])
        eq(w.sdk.enabled(), false)
        w.sdk.update(1)
        w.sdk.track('e', { a = 1 })
        w.sdk.flush()
        eq(w.sdk.submitFeedback('hi'), false)
        eq(w.sdk.getDeviceId(), nil)
        eq(w.sdk.getTransport(), nil)
        eq(w.sdk.quit(), false)
        local stop = w.sdk.on('session_ready', function() end)
        stop()
        eq(selected, false, 'no transport was even chosen')
        eq(next(w.files), nil, 'no files')
        eq(#w.lines, 1, 'nothing else printed')
        eq(w.sdk.init({ ingestKey = 'gt_live_k' }), nil, 'a second init is still ignored')
      end)
    end
  end },
  { 'optional = true silences the inert warning', function()
    run(nil, nil, function(w)
      eq(w.sdk.init({ optional = true }).reason, 'no_key')
      eq(#w.lines, 0)
    end)
  end },
  { 'a key that is not a string is still an error', function()
    run(nil, nil, function(w)
      local ok, err = pcall(w.sdk.init, { ingestKey = 42 })
      assert(not ok and tostring(err):find('ingestKey must be a string'), tostring(err))
    end)
  end },
  { 'inert, the player choice is still saved and reported, in both consent modes', function()
    run(nil, nil, function(w)
      w.sdk.init({ optional = true })
      eq(w.sdk.isTrackingEnabled(), true)
      w.sdk.setTrackingEnabled(false)
      eq(w.files.ravensight_optout, '1')
      eq(w.sdk.isTrackingEnabled(), false)
      eq(w.sdk.enabled(), false)
    end)
    run(nil, nil, function(w)
      w.sdk.init({ optional = true, consent = 'opt_in' })
      eq(w.sdk.isTrackingEnabled(), false, 'opt_in starts off')
      w.sdk.setTrackingEnabled(true)
      eq(w.files.ravensight_optin, '1')
      eq(w.files.ravensight_optout, nil)
      eq(w.sdk.isTrackingEnabled(), true)
      eq(w.sdk.enabled(), false, 'still inert this run')
      w.sdk.setTrackingEnabled(false)
      eq(w.files.ravensight_optin, nil)
    end)
  end },
  { 'enabled = false with consent = "opt_in" saves into ravensight_optin', function()
    run(nil, nil, function(w)
      w.sdk.init({ ingestKey = 'gt_live_k', enabled = false, consent = 'opt_in' })
      eq(w.sdk.isTrackingEnabled(), false)
      w.sdk.setTrackingEnabled(true)
      eq(w.files.ravensight_optin, '1')
      eq(w.sdk.isTrackingEnabled(), true)
    end)
  end },
  { 'on the web a key is not required: the page owns it', function()
    run('Web', nil, function(w)
      local result = w.sdk.init({})
      eq(result.reason, 'web_bridge')
      eq(w.sdk.enabled(), true)
      w.sdk.track('level_start', {})
      eq(w.after()[1].event, 'level_start')
    end)
  end },

  -- -------------------------------------------- 0.3.0: web and consent

  { 'web opt_in: the page is told off at start and nothing is printed until a yes', function()
    local files = {}
    run('Web', files, function(w)
      w.sdk.init({ consent = 'opt_in' })
      eq(#w.after(false), 0, 'opt_in with no saved yes: told off')
      eq(w.sdk.enabled(), false)
      w.sdk.track('ignored', {})
      eq(#w.ops(), 1)
      w.sdk.setTrackingEnabled(true)
      eq(w.ops()[2].value, true)
      eq(files.ravensight_optin, '1')
      eq(files.ravensight_optout, nil)
      w.sdk.track('counted', {})
      eq(w.ops()[3].event, 'counted')
    end)
    run('Web', files, function(w)
      w.sdk.init({ consent = 'opt_in' })
      eq(#w.after(true), 0, 'the yes is remembered and passed on')
    end)
  end },
  { 'web: an event over 8,192 bytes is not printed', function()
    run('Web', nil, function(w)
      w.sdk.init({})
      local failed
      w.sdk.on('flush_failed', function(reason) failed = reason end)
      w.sdk.track('huge', { blob = string.rep('x', 9000) })
      eq(#w.after(), 0)
      eq(failed, 'event_too_large')
    end)
  end },

  -- ------------------------------------- 0.3.0: what leaves the machine

  { 'a desktop run sends exactly the documented keys and no path, host name or arg', function()
    local secretArg = '--level-editor=/Users/someone/private/saves'
    run(nil, nil, function(w)
      local savedArg = _G.arg
      _G.arg = { 'game.love', secretArg, '--fused' }
      local sent = {}
      package.loaded['ravensight.transport'] = { select = function()
        return { name = 'fake', request = function(req)
          table.insert(sent, req)
          if req.url:find('/settings$') then return 200, '{"trackingEnabled":true}', {} end
          if req.url:find('/session$') then return 201, '{"token":"ses","expiresIn":3600}', {} end
          if req.url:find('/feedback$') then return 201, '{}', {} end
          return 202, '{}', {}
        end }
      end }
      local ok, err = pcall(function()
        w.sdk.init({ ingestKey = 'gt_pub_k', synchronous = true, distribution = 'native-release' })
        for _ = 1, 3 do w.sdk.update(0) end
        w.sdk.track('level_start', { level = 'forest_1' })
        w.sdk.flush()
        w.sdk.update(0)
        eq(w.sdk.submitFeedback('hi', 'bug', 4), true)
        w.sdk.update(0)
      end)
      _G.arg = savedArg
      if not ok then error(err, 0) end

      local function keys(t)
        local out = {}
        for k in pairs(t or {}) do out[#out + 1] = k end
        table.sort(out)
        return table.concat(out, ',')
      end
      local seen = {}
      for _, req in ipairs(sent) do
        local path = req.url:match('^https://api%.ravensight%.io(/.*)$')
        assert(path, 'only the API is called: ' .. req.url)
        seen[#seen + 1] = req.method .. ' ' .. path
        local body = req.body and json.decode(req.body)
        if path == '/api/v1/settings' then
          eq(keys(req.headers), 'X-API-Key'); eq(req.body, nil)
        elseif path == '/api/v1/session' then
          eq(keys(req.headers), 'Content-Type,X-API-Key')
          eq(keys(body), 'deviceId,distribution,gameVersion,platform')
        elseif path == '/api/v1/track/batch' then
          eq(keys(req.headers), 'Content-Type,X-Session-Token')
          eq(keys(body), 'events')
          for _, e in ipairs(body.events) do
            eq(keys(e), 'data,event,timestamp')
            local d = keys(e.data)
            assert(d == 'rs_event_id' or d == 'level,rs_event_id', d)
          end
        elseif path == '/api/v1/feedback' then
          eq(keys(req.headers), 'Content-Type,X-Session-Token')
          eq(keys(body), 'category,message,rating')
        else
          error('unexpected request ' .. path)
        end
        -- Nothing about the machine, the install or the command line.
        local everything = req.url .. json.encode(req.headers) .. (req.body or '')
        local hostname
        local pipe = io.popen('hostname')
        if pipe then hostname = (pipe:read('*l') or ''):match('^%s*(.-)%s*$'); pipe:close() end
        for _, needle in ipairs({ secretArg, '/Users/someone', 'game.love', '--fused', os.getenv('HOME') or '', os.getenv('PWD') or '', os.getenv('USER') or '', hostname or '' }) do
          if needle ~= '' and #needle > 2 then
            assert(not everything:find(needle, 1, true), 'leaked ' .. needle .. ' in ' .. everything)
          end
        end
      end
      eq(table.concat(seen, ' | '), 'GET /api/v1/settings | POST /api/v1/session | POST /api/v1/track/batch | POST /api/v1/track/batch | POST /api/v1/feedback')
    end)
  end },
}
