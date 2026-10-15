-- ravensight/typed.lua: the exact property set of every typed event, and the
-- health summary. No engine, no network: the builders are pure.

local Typed = require('ravensight.typed')
local json = require('ravensight.json')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local function keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return table.concat(out, ',')
end

--- A health sampler given exactly one sample per frame time listed.
local function sampled(frameTimes, deps)
  local health = Typed.Health.new(deps)
  for _, dt in ipairs(frameTimes) do
    health.elapsed = Typed.SAMPLE_SECONDS
    health:tick(dt)
  end
  return health
end

return {
  { 'purchase carries exactly its reserved keys, the currency upper-cased', function()
    local name, p = Typed.purchase(499, 'usd', 'bundle', 'starter', { cart = 'c1', transactionId = 't9' })
    eq(name, 'purchase')
    eq(keys(p), 'rs_amount,rs_cart,rs_currency,rs_item_id,rs_item_type,rs_kind,rs_transaction_id')
    eq(p.rs_kind, 'purchase'); eq(p.rs_amount, 499); eq(p.rs_currency, 'USD')
    eq(p.rs_item_type, 'bundle'); eq(p.rs_item_id, 'starter'); eq(p.rs_cart, 'c1'); eq(p.rs_transaction_id, 't9')
  end },
  { 'purchase leaves the optional keys out and passes a digit string or bad input through', function()
    local _, p = Typed.purchase('1999', 'eur', 'gem_pack', 'g1')
    eq(keys(p), 'rs_amount,rs_currency,rs_item_id,rs_item_type,rs_kind')
    eq(p.rs_amount, '1999'); eq(p.rs_currency, 'EUR')
    local _, bad = Typed.purchase(4.99, 12, nil, nil)
    eq(bad.rs_amount, 4.99, 'a float is passed on for the server to flag'); eq(bad.rs_currency, 12)
    eq(keys(bad), 'rs_amount,rs_currency,rs_kind')
  end },
  { 'resource names its event by flow and carries the optional item', function()
    local name, p = Typed.resource('source', 'gold', 50)
    eq(name, 'resource_source')
    eq(keys(p), 'rs_amount,rs_flow,rs_kind,rs_resource')
    eq(p.rs_kind, 'resource'); eq(p.rs_flow, 'source'); eq(p.rs_resource, 'gold'); eq(p.rs_amount, 50)
    local sinkName, sink = Typed.resource('sink', 'gold', 20, { itemType = 'weapon', itemId = 'axe' })
    eq(sinkName, 'resource_sink')
    eq(keys(sink), 'rs_amount,rs_flow,rs_item_id,rs_item_type,rs_kind,rs_resource')
  end },
  { 'progression names its event by status and carries the optional nodes and score', function()
    local name, p = Typed.progression('start', 'world1')
    eq(name, 'progression_start')
    eq(keys(p), 'rs_kind,rs_p1,rs_status')
    local doneName, done = Typed.progression('complete', 'world1', { p2 = 'level3', p3 = 'boss', score = 1250.5 })
    eq(doneName, 'progression_complete')
    eq(keys(done), 'rs_kind,rs_p1,rs_p2,rs_p3,rs_score,rs_status')
    eq(done.rs_score, 1250.5)
    eq((Typed.progression('fail', 'w')), 'progression_fail')
  end },
  { 'error cuts the message to 200 characters and the stack to 2000', function()
    local name, p = Typed.error('critical', string.rep('m', 500), { stack = string.rep('s', 3000) })
    eq(name, 'error')
    eq(keys(p), 'rs_kind,rs_message,rs_severity,rs_stack')
    eq(#p.rs_message, 200); eq(#p.rs_stack, 2000); eq(p.rs_severity, 'critical')
    local _, short = Typed.error('info', 'short')
    eq(short.rs_message, 'short'); eq(short.rs_stack, nil)
    eq(#select(2, Typed.error('error', string.rep('m', 200))).rs_message, 200, 'exactly 200 is kept')
  end },
  { 'a cut never ends inside a UTF-8 character', function()
    local text = string.rep('a', 199) .. '\xC3\xA9' .. 'tail' -- the e-acute straddles byte 200
    local _, p = Typed.error('error', text)
    eq(#p.rs_message, 199)
    eq(json.decode(json.encode(p)).rs_message, string.rep('a', 199))
  end },
  { 'reserved keys win over the caller\'s own properties, and the caller\'s table is untouched', function()
    local mine = { rs_kind = 'level', rs_amount = 1, level = 'forest', rs_flow = 'sink' }
    local _, p = Typed.resource('source', 'gold', 5, { props = mine })
    eq(p.rs_kind, 'resource'); eq(p.rs_amount, 5); eq(p.rs_flow, 'source'); eq(p.level, 'forest')
    eq(mine.rs_kind, 'level'); eq(mine.rs_amount, 1)
    local _, q = Typed.purchase(100, 'usd', 'a', 'b', { props = { rs_currency = 'XXX', rs_kind = 'none', note = 'hi' } })
    eq(q.rs_currency, 'USD'); eq(q.rs_kind, 'purchase'); eq(q.note, 'hi')
    local _, e = Typed.error('error', 'x', { props = { rs_severity = 'debug' } })
    eq(e.rs_severity, 'error')
    local _, g = Typed.progression('start', 'p', { props = { rs_status = 'fail' } })
    eq(g.rs_status, 'start')
  end },
  { 'the event name can be overridden on every helper', function()
    eq((Typed.purchase(1, 'usd', 'a', 'b', { name = 'iap' })), 'iap')
    eq((Typed.resource('sink', 'gold', 1, { name = 'spend' })), 'spend')
    eq((Typed.progression('start', 'p', { name = 'level_begin' })), 'level_begin')
    eq((Typed.error('error', 'x', { name = 'crash' })), 'crash')
  end },
  { 'no helper throws on missing or wrong-typed input', function()
    assert(pcall(Typed.purchase))
    assert(pcall(Typed.resource))
    assert(pcall(Typed.progression))
    assert(pcall(Typed.error))
    assert(pcall(Typed.purchase, {}, {}, {}, {}, 'not a table'))
    assert(pcall(Typed.error, 5, {}, { stack = 7, props = 'nope' }))
  end },

  -- ------------------------------------------------------------- health
  { 'health takes one sample per second of frame time, not one per frame', function()
    local health = Typed.Health.new()
    local taken = 0
    for _ = 1, 600 do
      if health:tick(1 / 60) then taken = taken + 1 end
    end
    eq(taken, 10, 'ten seconds of 60 fps frames')
    eq(health:summary().rs_fps_median, 60)
  end },
  { 'median and 10th percentile come from a known sample set', function()
    -- fps 10, 20, ..., 100 (ten samples)
    local times = {}
    for fps = 10, 100, 10 do times[#times + 1] = 1 / fps end
    local s = sampled(times):summary()
    eq(s.rs_kind, 'health')
    eq(s.rs_fps_median, 55, 'mean of the middle pair, 50 and 60')
    eq(s.rs_fps_p10, 10, 'nearest rank 1 of 10')
    eq(keys(s), 'rs_fps_median,rs_fps_p10,rs_kind')
    local odd = sampled({ 1 / 30, 1 / 60, 1 / 120 }):summary()
    eq(odd.rs_fps_median, 60); eq(odd.rs_fps_p10, 30)
    local twenty = {}
    for fps = 1, 20 do twenty[#twenty + 1] = 1 / fps end
    eq(sampled(twenty):summary().rs_fps_p10, 2, 'nearest rank 2 of 20')
  end },
  { 'memory and boot time are added when the platform has them', function()
    local s = sampled({ 1 / 60 }, { memoryMb = function() return 12.345 end, bootMs = 812.9 }):summary()
    eq(keys(s), 'rs_boot_ms,rs_fps_median,rs_fps_p10,rs_kind,rs_memory_mb')
    eq(s.rs_memory_mb, 12.3); eq(s.rs_boot_ms, 812)
    local none = sampled({ 1 / 60 }, { memoryMb = function() return nil end }):summary()
    eq(none.rs_memory_mb, nil); eq(none.rs_boot_ms, nil)
  end },
  { 'with no sample there is no summary', function()
    local health = Typed.Health.new()
    eq(health:summary(), nil)
    health:tick(0.5) -- half a second is not a sample yet
    eq(health:summary(), nil)
    eq(health:tick(0), false); eq(health:tick(nil), false); eq(health:tick(-1), false)
    eq(health:tick(0 / 0), false)
    eq(health:summary(), nil)
  end },
  { 'the reservoir never holds more than 600 samples', function()
    local health = Typed.Health.new({ random = function() return 0.25 end })
    for _ = 1, 2000 do
      health.elapsed = Typed.SAMPLE_SECONDS
      health:tick(1 / 50)
    end
    eq(#health.samples, 600); eq(health.seen, 2000)
    eq(health:summary().rs_fps_median, 50)
    -- Once full, a new second replaces a slot only when the draw lands in it.
    local late = Typed.Health.new({ random = function() return 0.999 end })
    for _ = 1, 600 do late.elapsed = 1; late:tick(1 / 60) end
    late.elapsed = 1; late:tick(1 / 10)
    eq(late.samples[600], 60, 'slot 601 of 601 is outside the reservoir: dropped')
  end },
}
