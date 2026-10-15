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
-- Nothing here validates or throws. Money is passed through as given: the
-- server stores a wrong amount as a flagged event (`rs_invalid`), which shows
-- on the Implementation health card.
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
