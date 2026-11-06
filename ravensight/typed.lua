-- ravensight/typed.lua: typed events and performance sampling, with no LÖVE
-- calls in it.
--
-- A typed event is an ordinary event whose data carries reserved `rs_*`
-- properties, so the platform can read a purchase, a resource flow, a
-- progression step, an error or a health sample without a schema. Each
-- builder here only returns the event name and the property table; the
-- caller hands both to the generic track, so queueing, batching, retries,
-- opt-out and the playtest path are unchanged.
--
-- Nothing here throws. Purchase money is passed through as given: the
-- server stores a wrong amount as a flagged event (`rs_invalid`), which shows
-- on the Implementation health card. The ad and attribution builders check
-- their fields and refuse a malformed event, so revenue without a currency
-- or a fractional amount of micros is never sent.
--
-- MIT licensed, part of ravensight-love.

local Typed = {}

Typed.MAX_MESSAGE_CHARS = 200
Typed.MAX_STACK_CHARS = 2000
Typed.MAX_SAMPLES = 600
Typed.SAMPLE_SECONDS = 1

--- Keeps at most `max` bytes of a string, never ending inside a UTF-8
--- character. Bytes are never fewer than characters, so the cut text is
--- within the server's character limit. Other types pass through.
function Typed.cut(value, max)
  if type(value) ~= 'string' or #value <= max then return value end
  local stop = max
  -- Back off while the next byte is a continuation byte (10xxxxxx).
  while stop > 0 do
    local b = value:byte(stop + 1)
    if b and b >= 0x80 and b < 0xC0 then stop = stop - 1 else break end
  end
  return value:sub(1, stop)
end

local function merged(extra)
  local out = {}
  if type(extra) == 'table' then
    for k, v in pairs(extra) do out[k] = v end
  end
  return out
end

local function set(out, key, value)
  if value ~= nil then out[key] = value end
end

--- opts: cart, transactionId, name (event name, default "purchase"),
--- props (extra properties, which the reserved keys override).
function Typed.purchase(amount, currency, itemType, itemId, opts)
  opts = opts or {}
  local out = merged(opts.props)
  out.rs_kind = 'purchase'
  set(out, 'rs_amount', amount)
  set(out, 'rs_currency', type(currency) == 'string' and currency:upper() or currency)
  set(out, 'rs_item_type', itemType)
  set(out, 'rs_item_id', itemId)
  set(out, 'rs_cart', opts.cart)
  set(out, 'rs_transaction_id', opts.transactionId)
  return opts.name or 'purchase', out
end

--- flow is "source" or "sink". opts: itemType, itemId, name (default
--- "resource_source" or "resource_sink"), props.
function Typed.resource(flow, resource, amount, opts)
  opts = opts or {}
  local out = merged(opts.props)
  out.rs_kind = 'resource'
  set(out, 'rs_flow', flow)
  set(out, 'rs_resource', resource)
  set(out, 'rs_amount', amount)
  set(out, 'rs_item_type', opts.itemType)
  set(out, 'rs_item_id', opts.itemId)
  return opts.name or ('resource_' .. tostring(flow)), out
end

--- status is "start", "complete" or "fail". opts: p2, p3, score, name
--- (default "progression_<status>"), props.
function Typed.progression(status, p1, opts)
  opts = opts or {}
  local out = merged(opts.props)
  out.rs_kind = 'progression'
  set(out, 'rs_status', status)
  set(out, 'rs_p1', p1)
  set(out, 'rs_p2', opts.p2)
  set(out, 'rs_p3', opts.p3)
  set(out, 'rs_score', opts.score)
  return opts.name or ('progression_' .. tostring(status)), out
end

--- severity is "debug", "info", "warning", "error" or "critical". The
--- message is cut to 200 characters and the stack to 2000. opts: stack,
--- name (default "error"), props.
function Typed.error(severity, message, opts)
  opts = opts or {}
  local out = merged(opts.props)
  out.rs_kind = 'error'
  set(out, 'rs_severity', severity)
  set(out, 'rs_message', Typed.cut(message, Typed.MAX_MESSAGE_CHARS))
  set(out, 'rs_stack', Typed.cut(opts.stack, Typed.MAX_STACK_CHARS))
  return opts.name or 'error', out
end

--- Characters as the server counts them: UTF-16 code units of UTF-8 text.
--- Each character is one unit, and one written in four bytes is two.
function Typed.utf16Length(text)
  local units = 0
  for i = 1, #text do
    local b = text:byte(i)
    if b < 0x80 or b >= 0xC0 then units = units + 1 end
    if b >= 0xF0 then units = units + 1 end
  end
  return units
end

-- -------------------------------------------------------- ads and attribution

Typed.AD_FORMATS = { banner = true, interstitial = true, rewarded = true, native = true, app_open = true, other = true }
Typed.AD_RESULTS = { shown = true, clicked = true, failed = true, rewarded = true }

local function text(value, max)
  return type(value) == 'string' and value ~= '' and Typed.utf16Length(value) <= max
end

local function present(value)
  return value ~= nil and value ~= ''
end

--- Revenue as the contract wants it: a digit string of 1 to 18 digits, from
--- a digit string or a whole non-negative number; nil for anything else
--- (a fraction, a decimal string, a negative).
local function microsText(value)
  if type(value) == 'string' and value:match('^%d+$') and #value <= 18 then return value end
  if type(value) == 'number' and value >= 0 and value % 1 == 0 and value <= 9007199254740991 then
    return string.format('%d', value)
  end
  return nil
end

--- One ad lifecycle step. network is 1 to 64 characters, format one of
--- banner, interstitial, rewarded, native, app_open, other, result one of
--- shown, clicked, failed, rewarded. opts: placement (1 to 100), revenueMicros
--- and currency (on shown only, together), name (default "rs_ad"), props.
--- Returns name, props, or nil and the reason it was refused.
function Typed.ad(network, format, result, opts)
  opts = opts or {}
  if not text(network, 64) then return nil, 'network is 1 to 64 characters' end
  if not Typed.AD_FORMATS[format] then return nil, 'format is banner, interstitial, rewarded, native, app_open or other' end
  if not Typed.AD_RESULTS[result] then return nil, 'result is shown, clicked, failed or rewarded' end
  local out = merged(opts.props)
  out.rs_kind = 'ad'
  out.rs_ad_network = network
  out.rs_ad_format = format
  out.rs_ad_result = result
  if present(opts.placement) then
    if not text(opts.placement, 100) then return nil, 'placement is at most 100 characters' end
    out.rs_ad_placement = opts.placement
  end
  if opts.revenueMicros ~= nil then
    local micros = microsText(opts.revenueMicros)
    if not micros then return nil, 'revenueMicros is a digit string of 1 to 18 digits, never a fraction' end
    if result ~= 'shown' then return nil, 'revenue goes on a shown ad only' end
    if type(opts.currency) ~= 'string' or not opts.currency:match('^%a%a%a$') then return nil, 'revenue needs a three letter currency' end
    out.rs_revenue_micros = micros
    out.rs_currency = opts.currency:upper()
  elseif opts.currency ~= nil then
    return nil, 'a currency is sent only with revenue'
  end
  return opts.name or 'rs_ad', out
end

--- Where this device was acquired. attribution: source (required, 1 to 64:
--- utm, store_referrer, organic or a partner name), network (1 to 100),
--- campaign, adset, creative (1 to 200 each), touchTime (epoch ms), name
--- (default "rs_attribution"). Empty fields are left out. Returns name,
--- props, or nil and the reason.
function Typed.attribution(attribution)
  attribution = attribution or {}
  if not text(attribution.source, 64) then return nil, 'source is 1 to 64 characters' end
  local out = { rs_kind = 'attribution', rs_attr_source = attribution.source }
  for _, field in ipairs({ { 'network', 'rs_attr_network', 100 }, { 'campaign', 'rs_campaign', 200 }, { 'adset', 'rs_adset', 200 }, { 'creative', 'rs_creative', 200 } }) do
    local value = attribution[field[1]]
    if present(value) then
      if not text(value, field[3]) then return nil, field[1] .. ' is at most ' .. field[3] .. ' characters' end
      out[field[2]] = value
    end
  end
  local touch = attribution.touchTime
  if touch ~= nil then
    if type(touch) ~= 'number' or touch < 0 or touch % 1 ~= 0 or touch > 9007199254740991 then
      return nil, 'touchTime is whole epoch milliseconds'
    end
    out.rs_touch_time = touch
  end
  return attribution.name or 'rs_attribution', out
end

--- Micros from decimal text in major units, worked on the digits so no
--- float is ever multiplied: "0.0015" is "1500", "1.23456789" is "1234568"
--- (half up at the seventh decimal). nil for anything that is not a plain
--- non-negative decimal or does not fit 18 digits.
function Typed.microsFromDecimalString(value)
  if type(value) ~= 'string' then return nil end
  local whole, fraction = value:match('^%s*(%d*)%.?(%d*)%s*$')
  if not whole or (whole == '' and fraction == '') or (value:find('%.') == nil and fraction ~= '') then return nil end
  fraction = fraction .. '0000000'
  local digits = (whole .. fraction:sub(1, 6)):gsub('^0+', '')
  if digits == '' then digits = '0' end
  if fraction:byte(7) >= 53 then
    local bytes = { digits:byte(1, -1) }
    local i = #bytes
    while i >= 1 and bytes[i] == 57 do bytes[i] = 48; i = i - 1 end
    if i >= 1 then bytes[i] = bytes[i] + 1 else table.insert(bytes, 1, 49) end
    digits = string.char(unpack(bytes))
  end
  if #digits > 18 then return nil end
  return digits
end

--- Micros from a mediation callback's revenue number in major units: it is
--- formatted to 6 decimals by string.format, then converted on its digits.
--- nil for a negative, infinite or NaN value.
function Typed.microsFromRevenue(value)
  if type(value) ~= 'number' or value ~= value or value < 0 or value == math.huge then return nil end
  return Typed.microsFromDecimalString(string.format('%.6f', value))
end

-- ------------------------------------------------------------------ health

local Health = {}
Health.__index = Health
Typed.Health = Health

--- deps:
---   random()      0 <= x < 1, for the reservoir once it is full
---   memoryMb()    megabytes in use, or nil where the platform has no figure
---   bootMs        milliseconds from process start to the SDK's start, or nil
function Health.new(deps)
  deps = deps or {}
  local self = setmetatable({}, Health)
  self.random = deps.random or math.random
  self.memoryMb = deps.memoryMb
  self.bootMs = deps.bootMs
  self.samples = {}
  self.seen = 0
  self.elapsed = 0
  self.sent = false
  return self
end

--- Call every frame with the frame time in seconds. Takes one sample per
--- second of play. Returns true when this call took a sample.
function Health:tick(dt)
  if type(dt) ~= 'number' or dt ~= dt or dt <= 0 then return false end
  self.elapsed = self.elapsed + dt
  if self.elapsed < Typed.SAMPLE_SECONDS then return false end
  self.elapsed = self.elapsed % Typed.SAMPLE_SECONDS
  self.seen = self.seen + 1
  local fps = 1 / dt
  if #self.samples < Typed.MAX_SAMPLES then
    self.samples[#self.samples + 1] = fps
  else
    -- Reservoir sampling: every second seen is equally likely to be kept.
    local slot = math.floor(self.random() * self.seen) + 1
    if slot <= Typed.MAX_SAMPLES then self.samples[slot] = fps end
  end
  return true
end

local function round(x, places)
  local m = 10 ^ places
  return math.floor(x * m + 0.5) / m
end

--- The summary properties, or nil when no sample was ever taken.
function Health:summary()
  local n = #self.samples
  if n == 0 then return nil end
  local sorted = {}
  for i = 1, n do sorted[i] = self.samples[i] end
  table.sort(sorted)
  local median
  if n % 2 == 1 then median = sorted[(n + 1) / 2] else median = (sorted[n / 2] + sorted[n / 2 + 1]) / 2 end
  -- Nearest rank: the 10th percentile of frames per second is the slow tail.
  local p10 = sorted[math.max(1, math.ceil(0.1 * n))]
  local out = {
    rs_kind = 'health',
    rs_fps_median = round(median, 2),
    rs_fps_p10 = round(p10, 2),
  }
  local mem = self.memoryMb and self.memoryMb()
  if type(mem) == 'number' then out.rs_memory_mb = round(mem, 1) end
  if type(self.bootMs) == 'number' then out.rs_boot_ms = math.floor(self.bootMs) end
  return out
end

return Typed
