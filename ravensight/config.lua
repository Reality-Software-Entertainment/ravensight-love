-- Bounded public config validation shared by desktop and web clients.
local json = require(((...):gsub('config$', 'json')))
local Config = {}
local function identifier(value, limit, variant)
  return type(value) == 'string' and #value <= limit and value:match(variant and '^[a-z][a-z0-9_%-]*$' or '^[a-z][a-z0-9_]*$') ~= nil
end
local function safe(value, depth)
  if depth > 20 then return false end
  if value == json.null then return true end
  if type(value) == 'number' then return value == value and value ~= math.huge and value ~= -math.huge end
  if type(value) == 'table' then
    for k, v in pairs(value) do
      if k == '__proto__' or k == 'prototype' or k == 'constructor' or not safe(v, depth + 1) then return false end
    end
    return true
  end
  return type(value) == 'string' or type(value) == 'boolean'
end
function Config.values(values)
  if type(values) ~= 'table' then return false end
  local count = 0
  for k, v in pairs(values) do
    count = count + 1
    if count > 50 or not identifier(k, 64) or not safe(v, 0) then return false end
    local ok, text = pcall(json.encode, v)
    if not ok or #text > 8192 then return false end
  end
  return true
end
function Config.valid(doc)
  if type(doc) ~= 'table' or not Config.values(doc.values) or type(doc.experiments) ~= 'table' or type(doc.etag) ~= 'string' or #doc.etag ~= 66 or not doc.etag:match('^"[a-f0-9]+"$') then return false end
  local seen, count = {}, 0
  for i, row in pairs(doc.experiments) do
    count = count + 1
    if type(i) ~= 'number' or i % 1 ~= 0 or i < 1 or i > #doc.experiments or count > 10 or type(row) ~= 'table' or not identifier(row.key, 64) or not identifier(row.variant, 40, true) or seen[row.key] then return false end
    seen[row.key] = true
  end
  return true
end
function Config.get(values, key, fallback)
  local value = values and values[key]
  if value == nil or value == json.null or type(value) ~= type(fallback) then return fallback end
  if type(value) == 'table' then return json.decode(json.encode(value)) end
  return value
end
function Config.encode(value)
  return (tostring(value):gsub('[^%w%-%._~]', function(c) return string.format('%%%02X', string.byte(c)) end))
end
return Config
