local transport = require('ravensight.transport')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

return {
  { 'shell quoting survives a single quote and shell metacharacters', function()
    eq(transport._shellQuote("it's $(rm -rf /)"), "'it'\\''s $(rm -rf /)'")
  end },
  { 'the curl command quotes every value that came from the request', function()
    local cmd = transport._curlCommand({
      method = 'POST',
      url = "https://api.example.com/api/v1/session?x='y'",
      headers = { ['X-API-Key'] = "gt_live_'; touch /tmp/pwned; '", ['Content-Type'] = 'application/json' },
      body = '{}',
      timeout = 5,
    }, '/tmp/body', '/tmp/headers')
    assert(cmd:find("--header 'Content-Type: application/json'", 1, true))
    assert(cmd:find("'X-API-Key: gt_live_'\\''; touch /tmp/pwned; '\\'''", 1, true), cmd)
    assert(cmd:find("--data-binary '@/tmp/body'", 1, true))
    assert(cmd:find("'https://api.example.com/api/v1/session?x='\\''y'\\'''", 1, true))
    assert(cmd:find('--max-time 5', 1, true))
  end },
  { 'response header names are lowercased and values trimmed', function()
    local h = transport._lowerHeaders('HTTP/1.1 429 Too Many Requests\r\nRetry-After:  30 \r\nContent-Type: application/json\r\n')
    eq(h['retry-after'], '30')
    eq(h['content-type'], 'application/json')
  end },
  { 'select() finds a working transport on this machine', function()
    local chosen = transport.select()
    assert(chosen, 'expected libcurl or curl on a development machine')
    assert(chosen.name == 'libcurl' or chosen.name == 'curl' or chosen.name == 'https' or chosen.name == 'winhttp')
  end },
  { 'a preferred transport is tried first', function()
    local chosen = transport.select('curl')
    eq(chosen and chosen.name, 'curl')
  end },
}
