local expectedLength = require('ravensight.transport')._winHttpExpectedLength
local readBody = require('ravensight.transport')._readWinHttpBody

-- Only the DLL/FFI boundary is replaced: these exercise the production reader.
local function read(script, limit, expectedLength)
  local step, index = nil, 0
  local ffi = {
    new = function() return {[0] = 0} end,
    string = function(buf, size) return buf.bytes:sub(1, size) end,
  }
  local lib = {
    WinHttpQueryDataAvailable = function(_, available)
      index = index + 1
      step = assert(script[index], 'unexpected extra native read')
      if step.queryError then return 0 end
      available[0] = step.available or #(step.bytes or '')
      return 1
    end,
    WinHttpReadData = function(_, buf, _, count)
      if step.readError then return 0 end
      buf.bytes = step.bytes or ''
      count[0] = step.readCount or #buf.bytes
      return 1
    end,
  }
  local body, err = readBody(lib, ffi, {}, limit or 65536, expectedLength)
  return body, err, index
end

local function fails(script, expected)
  local body, err = read(script)
  assert(body == nil, 'must discard all received bytes on native failure')
  assert(err == (expected or 'network_error'), tostring(err))
end

return {
  {'WinHTTP malformed and overflow lengths fail closed', function()
    for _, value in ipairs({'-1', '1.5', 'NaN', '1, 1', '', '9007199254740992', string.rep('9', 400)}) do
      local length, err = expectedLength({['content-length']=value}, 'GET', 200, 65536)
      assert(length == nil and err == 'network_error', value)
    end
  end},
  {'WinHTTP declared body beyond cap fails before read', function()
    local length, err = expectedLength({['content-length']='65537'}, 'GET', 200, 65536)
    assert(length == nil and err == 'response_too_large')
  end},
  {'WinHTTP valid length is a byte count', function()
    local length, err = expectedLength({['content-length']='0003'}, 'GET', 200, 65536)
    assert(length == 3 and err == nil)
  end},
  {'WinHTTP bodyless and transfer-coded responses ignore representation length', function()
    for _, status in ipairs({100, 204, 304}) do
      local length, err = expectedLength({['content-length']='100'}, 'GET', status, 10)
      assert(length == nil and err == nil)
    end
    local length, err = expectedLength({['content-length']='100'}, 'HEAD', 200, 10)
    assert(length == nil and err == nil)
    length, err = expectedLength({['content-length']='100', ['transfer-encoding']='chunked'}, 'GET', 200, 10)
    assert(length == nil and err == nil)
  end},
  {'WinHTTP normal EOF before declared length discards partial response', function()
    local body, err = read({{bytes='partial'}, {available=0}}, nil, 100)
    assert(body == nil and err == 'network_error')
  end},
  {'WinHTTP exact declared binary length succeeds', function()
    local body, err = read({{bytes='a\0b'}, {available=0}}, nil, 3)
    assert(body == 'a\0b' and err == nil)
  end},
  {'WinHTTP declared zero length accepts empty response', function()
    local body, err = read({{available=0}}, nil, 0)
    assert(body == '' and err == nil)
  end},
  {'WinHTTP query failure before first byte is not EOF', function()
    fails({{queryError=true}})
  end},
  {'WinHTTP query failure after bytes discards partial success', function()
    fails({{bytes='partial'}, {queryError=true}})
  end},
  {'WinHTTP read failure after bytes discards partial success', function()
    fails({{bytes='partial'}, {available=5, readError=true}})
  end},
  {'WinHTTP read failure before first byte fails', function()
    fails({{available=5, readError=true}})
  end},
  {'WinHTTP zero progress fails instead of looping or accepting EOF', function()
    fails({{bytes='partial'}, {available=5, readCount=0}})
  end},
  {'WinHTTP impossible read length is rejected', function()
    fails({{available=1, bytes='xx', readCount=2}})
  end},
  {'WinHTTP successful empty response remains valid', function()
    local body, err = read({{available=0}})
    assert(body == '' and err == nil)
  end},
  {'WinHTTP successful binary chunks retain exact bytes', function()
    local body, err, calls = read({{bytes='a\0'}, {bytes='\255z'}, {available=0}})
    assert(body == 'a\0\255z' and err == nil and calls == 3)
  end},
  {'WinHTTP cumulative size limit fails without reading excess bytes', function()
    local body, err, calls = read({{bytes='abcd'}, {available=5}}, 8)
    assert(body == nil and err == 'response_too_large' and calls == 2)
  end},
}
