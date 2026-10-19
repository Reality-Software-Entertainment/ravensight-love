-- Actual native transport acceptance. The Python runner supplies only loopback.
package.path = './?.lua;./?/init.lua;' .. package.path
local base, name = assert(arg[1]), assert(arg[2])
assert(base:match('^http://127%.0%.0%.1:%d+$'), 'loopback only')
assert(name == 'winhttp' or name == 'libcurl', 'explicit native transport required')
local transport = assert(require('ravensight.transport').select(name, true))
assert(transport.name == name, 'requested native transport unavailable; refusing fallback')
local passed = 0
local ffi = require('ffi')
local clock
if ffi.os == 'Windows' then
  ffi.cdef('unsigned long long GetTickCount64(void);')
  clock = function() return tonumber(ffi.C.GetTickCount64()) end
end
local function request(path, body, limit, timeout)
  return transport.request({url=base..path, method=body and 'POST' or 'GET',
    body=body, headers=body and {['Content-Type']='application/octet-stream'} or {},
    maxResponseBytes=limit or 65536, timeout=timeout or 2})
end
local function check(label, test)
  test()
  passed = passed + 1
  print('PASS '..label)
end
check('binary body and query retained', function()
  local status, body = request('/echo?part=one%20two&n=2', 'prefix\0\255suffix')
  assert(status == 200 and body == 'prefix\0\255suffix')
end)
check('redirect refused', function()
  local status = request('/redirect')
  assert(status == 302, 'must expose redirect without following it')
end)
check('oversized body rejected', function()
  local status = request('/large', nil, 1024)
  assert(status == 0, 'oversized body must fail')
end)
check('oversized headers rejected', function()
  local status = request('/headers', nil, 1024)
  assert(status == 0, 'oversized headers must fail')
end)
check('truncated body rejected', function()
  local status = request('/truncated')
  assert(status == 0, 'incomplete transfer must not report HTTP success')
end)
check('receive timeout bounded', function()
  local started = clock and clock()
  local status = request('/slow', nil, 65536, 0.15)
  if started then print('TIMEOUT requested_ms=150 delay_ms=5000 elapsed_ms='..(clock()-started)..' status='..status) end
  assert(status == 0, 'timed out transfer must fail; received status '..tostring(status))
end)
if clock then
  for _, seconds in ipairs({0.5, 1.5}) do
    check('receive timeout sweep '..seconds, function()
      local started = clock()
      local status = request('/slow', nil, 65536, seconds)
      local elapsed = clock()-started
      print('TIMEOUT requested_ms='..(seconds*1000)..' delay_ms=5000 elapsed_ms='..elapsed..' status='..status)
      assert(status==0 and elapsed<4500, 'stalled response must fail before fixture responds')
    end)
  end
  check('record subsecond timeout resolution against short delay', function()
    local started = clock()
    local status = request('/slow-short', nil, 65536, 0.15)
    print('TIMEOUT requested_ms=150 delay_ms=1000 elapsed_ms='..(clock()-started)..' status='..status)
    assert(status==0 or status==200, 'unexpected fixture status')
  end)
end
print(string.format('%s: %d native loopback checks passed', name, passed))
