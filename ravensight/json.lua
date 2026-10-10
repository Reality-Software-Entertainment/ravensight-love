-- ravensight/json.lua: a small JSON encoder and decoder for the Ravensight
-- SDK. Enough for event payloads and API responses, nothing more:
--
--   * a table with keys 1..n (and nothing else) encodes as an array, any
--     other table as an object with its keys converted to strings
--   * an empty table encodes as an object, {}, since event data is an object
--   * NaN and infinities cannot be represented in JSON and encode as null
--   * cyclic tables raise an error rather than recursing forever
--
-- MIT licensed, part of ravensight-love.

local json = {}

local escapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
    n = n + 1
  end
  if n == 0 then return false end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local encode_value

local function encode_table(t, seen)
  if seen[t] then error('json: cannot encode a cyclic table') end
  seen[t] = true
  local out = {}
  if is_array(t) then
    for i = 1, #t do out[i] = encode_value(t[i], seen) end
    seen[t] = nil
    return '[' .. table.concat(out, ',') .. ']'
  end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = tostring(k) end
  -- Sorted, so the same table always encodes to the same bytes.
  table.sort(keys)
  local lookup = {}
  for k, v in pairs(t) do lookup[tostring(k)] = v end
  for i, k in ipairs(keys) do
    out[i] = escape_string(k) .. ':' .. encode_value(lookup[k], seen)
  end
  seen[t] = nil
  return '{' .. table.concat(out, ',') .. '}'
end

encode_value = function(v, seen)
  local kind = type(v)
  if v == nil or v == json.null then return 'null' end
  if kind == 'boolean' then return tostring(v) end
  if kind == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end
    if v % 1 == 0 and v >= -2^53 and v <= 2^53 then
      return string.format('%d', v)
    end
    return string.format('%.17g', v)
  end
  if kind == 'string' then return escape_string(v) end
  if kind == 'table' then return encode_table(v, seen) end
  -- Functions, userdata and threads have no JSON form; say what it was.
  return escape_string('<' .. kind .. '>')
end

--- Encode a Lua value as a JSON string.
function json.encode(value)
  return encode_value(value, {})
end

-- A sentinel for JSON null inside arrays, where a plain nil would end the
-- array early. Decoded nulls in objects simply leave the key absent.
json.null = setmetatable({}, { __tostring = function() return 'null' end })

local function decode_error(str, pos, message)
  error(string.format('json: %s at position %d', message, pos), 0)
end

local function skip_ws(str, pos)
  return str:find('[^ \t\r\n]', pos) or #str + 1
end

local decode_value

local function codepoint_to_utf8(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then
    return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
  end
  if n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  end
  return string.char(
    0xF0 + math.floor(n / 0x40000), 0x80 + math.floor(n / 0x1000) % 0x40,
    0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
end

local function decode_string(str, pos)
  local out = {}
  local i = pos + 1
  while true do
    local c = str:sub(i, i)
    if c == '' then decode_error(str, i, 'unterminated string') end
    if c == '"' then return table.concat(out), i + 1 end
    if c == '\\' then
      local e = str:sub(i + 1, i + 1)
      local simple = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
      if simple[e] then
        out[#out + 1] = simple[e]
        i = i + 2
      elseif e == 'u' then
        local hex = str:sub(i + 2, i + 5)
        if not hex:match('^%x%x%x%x$') then decode_error(str, i, 'bad unicode escape') end
        local n = tonumber(hex, 16)
        i = i + 6
        -- A surrogate pair is two escapes that make one code point.
        if n >= 0xD800 and n <= 0xDBFF and str:sub(i, i + 1) == '\\u' then
          local low = tonumber(str:sub(i + 2, i + 5), 16)
          if low and low >= 0xDC00 and low <= 0xDFFF then
            n = 0x10000 + (n - 0xD800) * 0x400 + (low - 0xDC00)
            i = i + 6
          end
        end
        out[#out + 1] = codepoint_to_utf8(n)
      else
        decode_error(str, i, 'bad escape')
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

decode_value = function(str, pos)
  pos = skip_ws(str, pos)
  local c = str:sub(pos, pos)
  if c == '{' then
    local obj = {}
    pos = skip_ws(str, pos + 1)
    if str:sub(pos, pos) == '}' then return obj, pos + 1 end
    while true do
      pos = skip_ws(str, pos)
      if str:sub(pos, pos) ~= '"' then decode_error(str, pos, 'expected a key') end
      local key
      key, pos = decode_string(str, pos)
      pos = skip_ws(str, pos)
      if str:sub(pos, pos) ~= ':' then decode_error(str, pos, 'expected ":"') end
      local value
      value, pos = decode_value(str, pos + 1)
      if value ~= json.null then obj[key] = value end
      pos = skip_ws(str, pos)
      local sep = str:sub(pos, pos)
      if sep == '}' then return obj, pos + 1 end
      if sep ~= ',' then decode_error(str, pos, 'expected "," or "}"') end
      pos = pos + 1
    end
  elseif c == '[' then
    local arr = {}
    pos = skip_ws(str, pos + 1)
    if str:sub(pos, pos) == ']' then return arr, pos + 1 end
    while true do
      local value
      value, pos = decode_value(str, pos)
      arr[#arr + 1] = value
      pos = skip_ws(str, pos)
      local sep = str:sub(pos, pos)
      if sep == ']' then return arr, pos + 1 end
      if sep ~= ',' then decode_error(str, pos, 'expected "," or "]"') end
      pos = pos + 1
    end
  elseif c == '"' then
    return decode_string(str, pos)
  elseif str:sub(pos, pos + 3) == 'true' then
    return true, pos + 4
  elseif str:sub(pos, pos + 4) == 'false' then
    return false, pos + 5
  elseif str:sub(pos, pos + 3) == 'null' then
    return json.null, pos + 4
  else
    local num = str:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
    if not num or num == '' or num == '-' then decode_error(str, pos, 'unexpected character') end
    local n = tonumber(num)
    if not n then decode_error(str, pos, 'bad number') end
    return n, pos + #num
  end
end

--- Decode a JSON string. Returns the value, or nil and an error message.
function json.decode(str)
  if type(str) ~= 'string' then return nil, 'json: expected a string' end
  local ok, value, pos = pcall(decode_value, str, 1)
  if not ok then return nil, value end
  if skip_ws(str, pos) <= #str then return nil, 'json: trailing characters' end
  if value == json.null then return nil end
  return value
end

return json
