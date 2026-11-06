-- ravensight/errors.lua: the device scrub, the dedupe key, the caps and the
-- trail. The scrub vectors' expected outputs were produced by the server's
-- own scrub (src/services/errorScrub.js) on the same inputs.

local Errors = require('ravensight.errors')
local json = require('ravensight.json')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local VECTORS = {
  { 'main.lua:10: attempt to index a nil value (field \'player\')', 'main.lua:10: attempt to index a nil value (field \'player\')' },
  { 'GET https://user:pw@api.example.com/v1/x?token=abc#frag failed', 'GET https://api.example.com/v1/x failed' },
  { 'Authorization: Bearer abc.def-ghi_123== end', 'Authorization: [token] end' },
  { 'jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig here', 'jwt [token] here' },
  { 'key gt_live_abc123 and gt_pub_x', 'key [token] and [token]' },
  { 'mail jane.doe+x@example.co.uk now', 'mail [email] now' },
  { '/Users/jacob/game/main.lua:3: boom', '~/game/main.lua:3: boom' },
  { '/home/ann/proj/x.lua:1:', '~/proj/x.lua:1:' },
  { 'C:\\Users\\Bob\\AppData\\x.lua and c:/users/bob/y', '~\\AppData\\x.lua and ~/y' },
  { 'from 192.168.0.1 and 1234.1.1.1 and 10.0.0.256', 'from [ip] and 1234.1.1.1 and [ip]' },
  { 'v6 2001:0db8:85a3:0000:0000:8a2e:0370:7334 and ::1 and fe80::1ff:fe23:4567:890a and Foo::bar and 12:30:45', 'v6 [ip] and [ip] and [ip] and Foo::bar and 12:30:45' },
  { 'run 0123456789abcdef0123456789abcdef and OnPointerClickHandlerImplementationXYZ', 'run [token] and OnPointerClickHandlerImplementationXYZ' },
  { 'path a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q1 and aaaaaaaaaaaaaaaaaaaaaa1/b', 'path a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q1 and aaaaaaaaaaaaaaaaaaaaaa1/b' },
  { 'padded QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo1234== x', 'padded [token] x' },
  { '[love "boot.lua"]:345: in function <[love "boot.lua"]:341>', '[love "boot.lua"]:345: in function <[love "boot.lua"]:341>' },
  { 'ftp://host/path#x mailto:x@y.zz', 'ftp://host/path mailto:[email]' },
  { 'Bearer   tok', '[token]' },
  { 'deadbeef12345678 ok', 'deadbeef12345678 ok' },
}

local function clock()
  local c = { t = 0 }
  c.now = function() return c.t end
  return c
end

local function capture(e, message, opts)
  opts = opts or {}
  opts.source = opts.source or 'crash'
  opts.message = message
  return e:capture(opts)
end

return {
  { 'the scrub matches the server scrub, vector for vector', function()
    for _, v in ipairs(VECTORS) do eq(Errors.scrub(v[1]), v[2], v[1]) end
  end },
  { 'the scrub is idempotent and passes non-strings through', function()
    for _, v in ipairs(VECTORS) do eq(Errors.scrub(Errors.scrub(v[1])), v[2]) end
    eq(Errors.scrub(nil), nil); eq(Errors.scrub(5), 5); eq(Errors.scrub(''), '')
  end },
  { 'a 32 character run with no digit survives, one with a digit does not', function()
    eq(Errors.scrub('on_pointer_click_handler_for_the_menu'), 'on_pointer_click_handler_for_the_menu')
    eq(Errors.scrub(string.rep('a', 31) .. '1'), '[token]')
    eq(Errors.scrub(string.rep('a', 30) .. '1'), string.rep('a', 30) .. '1')
  end },
  { 'the shared contract vectors (spec/scrub-vectors.json), every case', function()
    local f = assert(io.open('spec/scrub-vectors.json', 'r'))
    local fixture = json.decode(f:read('*a'))
    f:close()
    assert(#fixture.cases > 0)
    for _, case in ipairs(fixture.cases) do
      eq(Errors.scrub(case['in']), case.out, case.name)
      eq(Errors.scrub(case.out), case.out, case.name .. ' (idempotent)')
    end
  end },
  { 'input is cut to 4 times the limit before the scrub, so 200,000 characters scrub fast', function()
    local big = string.rep('ab:cd 1.2.3.4 x@y.co ', 10000) -- over 200,000 characters
    assert(#big >= 200000)
    local started = os.clock()
    local e = Errors.new({ now = function() return 0 end })
    local data = e:capture({ source = 'crash', message = big, stack = big, trail = true })
    e:record('info', big)
    eq(#data.rs_message <= 200, true); eq(#data.rs_stack <= 2000, true)
    assert(data.rs_message:find('[ip]', 1, true))
    eq(#Errors.scrubField(big, 200), 200)
    assert(os.clock() - started < 0.5, 'took ' .. (os.clock() - started) .. ' s')
  end },
  { 'URLs lose user:password@ and an IPv6 match needs a digit', function()
    eq(Errors.scrub('https://bob:hunter2@host.example/p?q=1'), 'https://host.example/p')
    eq(Errors.scrub('Face::Add and fe80::1'), 'Face::Add and [ip]')
  end },
  { 'a path keeps its file, a secret with slashes does not', function()
    local path = 'res://addons/inventory_system2/ui/inventory_slot.gd:12'
    eq(Errors.scrub(path), path)
    eq(Errors.scrub('aws wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY1 leaked'), 'aws [token] leaked')
    eq(Errors.scrub('a/' .. string.rep('b', 31) .. '1/c.lua'), '[token].lua', 'a piece of 32 is not a path word')
    eq(Errors.scrub('k=' .. string.rep('a', 30) .. '1=='), '[token]', '= is in the run class')
  end },
  { 'the template takes out numbers, hex, ids, urls and quoted text', function()
    eq(Errors.template('main.lua:10: bad "x" at 12 in deadbeef99 https://a.b/c'), 'main.lua:0: bad "*" at 0 in <hex> <url>')
    eq(Errors.template('a 123e4567-e89b-12d3-a456-426614174000 b'), 'a <id> b')
  end },
  { 'the first in-app frame skips the SDK, LÖVE and C frames', function()
    local stack = '\t[C]: in function \'error\'\n\tlib/ravensight/init.lua:9: in function <x>\n\t[love "boot.lua"]:3: in x\n\tgame/enemy.lua:42: in function \'hit\''
    eq(Errors.firstFrame(stack), 'game/enemy.lua')
    eq(Errors.firstFrame('main.lua:10: boom'), 'main.lua')
    eq(Errors.firstFrame('[C]: in ?'), nil)
  end },
  { 'a capture has the contract keys, scrubbed and cut, and never rs_fp', function()
    local e = Errors.new({ now = clock().now })
    local data = capture(e, 'main.lua:1: mail a@b.co ' .. string.rep('x', 300), { stack = '/Users/ann/main.lua:1: in main', severity = 'error', errorType = string.rep('T', 150) })
    eq(data.rs_kind, 'error'); eq(data.rs_severity, 'error'); eq(data.rs_source, 'crash')
    eq(#data.rs_message, 200); assert(data.rs_message:find('[email]', 1, true))
    eq(data.rs_stack, '~/main.lua:1: in main')
    eq(#data.rs_error_type, 100)
    eq(data.rs_fp, nil); eq(data.rs_trail, nil)
  end },
  { 'caps: 3 per dedupe key, then the bucket of 6 a minute, then 30 a launch', function()
    local c = clock()
    local e = Errors.new({ now = c.now })
    for i = 1, 3 do assert(capture(e, 'main.lua:5: boom ' .. i), 'same key ' .. i) end
    eq(capture(e, 'main.lua:5: boom 4'), nil, 'a fourth with the same template is dropped')
    for i = 1, 3 do assert(capture(e, 'other.lua:1: e' .. string.char(96 + i))) end
    eq(capture(e, 'other.lua:1: ed'), nil, 'the bucket is empty after 6')
    c.t = 10
    assert(capture(e, 'other.lua:1: ee'), 'one token back after 10 seconds')
    eq(capture(e, 'other.lua:1: ef'), nil)
    local sent = 7
    for i = 1, 100 do
      c.t = c.t + 60
      if capture(e, 'k' .. string.rep('z', i) .. '.lua:1: x') then sent = sent + 1 end
    end
    eq(sent, 30, 'at most 30 captures in all')
  end },
  { 'the trail: last 20 lines, scrubbed, cut to 120, times from start, at most 10', function()
    local c = clock()
    local e = Errors.new({ now = c.now })
    for i = 1, 25 do
      c.t = i / 10
      e:record('info', 'line ' .. i .. ' from 10.0.0.1 ' .. string.rep('y', i == 25 and 200 or 0))
    end
    local trail = e:trail()
    local lines = {}
    for l in trail:gmatch('[^\n]+') do lines[#lines + 1] = l end
    eq(#lines, 20); eq(lines[1], '+600 info line 6 from [ip] ')
    eq(#lines[20], 120)
    assert(#trail <= 1500)
    local withTrail = 0
    for i = 1, 30 do
      c.t = c.t + 60
      local d = capture(e, 'f' .. i .. 'x.lua:1: y' .. string.rep('q', i), { trail = true })
      if d and d.rs_trail then withTrail = withTrail + 1 end
    end
    eq(withTrail, 10)
  end },
  { 'a held boot capture carries the trail without counting it until claimed', function()
    local e = Errors.new({ now = clock().now })
    e:record('info', 'loading')
    local d = capture(e, 'main.lua:1: early', { trail = 'held' })
    eq(d.rs_trail, '+0 info loading'); eq(e.trails, 0, 'not counted while held')
    eq(e:claimTrail(), true); eq(e.trails, 1)
    e.trails = Errors.MAX_TRAILS
    eq(e:claimTrail(), false, 'over the cap the held trail is not sent')
  end },
  { 'the trail is never attached with the switch off', function()
    local e = Errors.new({ now = clock().now })
    e:record('info', 'hello')
    eq(capture(e, 'main.lua:1: x').rs_trail, nil)
  end },
  { 'the trail is cut to 1,500 characters by dropping the oldest lines', function()
    local e = Errors.new({ now = clock().now })
    for _ = 1, 20 do e:record('info', string.rep('w', 200)) end
    local trail = e:trail()
    assert(#trail <= 1500, #trail)
    eq(select(2, trail:gsub('\n', '')) + 1, 12)
  end },
  { 'isAutomatic is true only for an error with an automatic source', function()
    eq(Errors.isAutomatic({ rs_kind = 'error', rs_source = 'crash' }), true)
    eq(Errors.isAutomatic({ rs_kind = 'error' }), false)
    eq(Errors.isAutomatic({ rs_kind = 'error', rs_source = 'manual' }), false)
    eq(Errors.isAutomatic({ rs_source = 'crash' }), false)
  end },
}
