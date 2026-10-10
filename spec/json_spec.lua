local json = require('ravensight.json')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

return {
  { 'encodes objects with sorted keys and arrays in order', function()
    eq(json.encode({ b = 1, a = 'x' }), '{"a":"x","b":1}')
    eq(json.encode({ 1, 2, 3 }), '[1,2,3]')
    eq(json.encode({ events = { { event = 'e', data = {}, timestamp = 5 } } }),
      '{"events":[{"data":{},"event":"e","timestamp":5}]}')
  end },
  { 'an empty table is an object, because event data is an object', function()
    eq(json.encode({}), '{}')
  end },
  { 'escapes quotes, backslashes and control characters', function()
    eq(json.encode('a"b\\c\n\1'), '"a\\"b\\\\c\\n\\u0001"')
  end },
  { 'keeps integers integral and encodes NaN and infinity as null', function()
    eq(json.encode(1791665783), '1791665783')
    eq(json.encode(0.5), '0.5')
    eq(json.encode(0 / 0), 'null')
    eq(json.encode(math.huge), 'null')
  end },
  { 'refuses a cyclic table instead of recursing forever', function()
    local t = {}
    t.self = t
    assert(not pcall(json.encode, t))
  end },
  { 'decodes what the API sends', function()
    local v = json.decode('{"token":"ses_abc","expiresIn":86400,"ok":true,"none":null,"list":[1,"two",{"x":-1.5e2}]}')
    eq(v.token, 'ses_abc')
    eq(v.expiresIn, 86400)
    eq(v.ok, true)
    eq(v.none, nil)
    eq(v.list[2], 'two')
    eq(v.list[3].x, -150)
  end },
  { 'decodes unicode escapes, including surrogate pairs', function()
    eq(json.decode('"caf\\u00e9 \\ud83d\\udc26"'), 'café 🐦')
  end },
  { 'returns nil and a message for malformed input rather than throwing', function()
    local v, err = json.decode('{"a":')
    eq(v, nil)
    assert(err)
    eq(json.decode('<html>'), nil)
    eq(json.decode('{} trailing'), nil)
    eq(json.decode(nil), nil)
  end },
  { 'round-trips nested data', function()
    local data = { level = 'forest_1', score = 1200, perfect = false, tags = { 'a', 'b' } }
    local back = json.decode(json.encode(data))
    eq(back.level, 'forest_1'); eq(back.score, 1200); eq(back.perfect, false); eq(back.tags[2], 'b')
  end },
}
