-- The delivery, ads and attribution, exposure and device contracts.
local Core = require('ravensight.core')
local Typed = require('ravensight.typed')
local Hmac = require('ravensight.hmac')
local Web = require('ravensight.web')
local json = require('ravensight.json')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local KEY = 'gt_pub_k'
local ORIGIN_A = { session = 'ses_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', build = '1.0.0', platform = 'macOS', stamp = 'o1.aaa.bbb' }
local ORIGIN_B = { session = 'ses_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', build = '1.1.0', platform = 'macOS', stamp = 'o1.ccc.ddd' }
local SECRET = 'dGVzdC1zZWNyZXQtZm9yLWRlbGl2ZXJ5LWNvbnRyYWN0'

local function vectors()
  local f = assert(io.open('spec/delivery-vectors.json', 'rb'))
  local text = f:read('*a')
  f:close()
  return json.decode(text)
end

local function expand(value)
  if type(value) == 'table' and value['repeat'] then return string.rep(value['repeat'], value.count) end
  if type(value) == 'table' then
    local out = {}
    for k, v in pairs(value) do out[k] = expand(v) end
    return out
  end
  return value
end

local function harness(opts)
  opts = opts or {}
  local h = { requests = {}, files = opts.files or {}, clock = 0, wall = 1800000000, events = {}, logs = {}, replaced = 0 }
  h.core = Core.new({
    apiUrl = 'https://api.test',
    ingestKey = KEY,
    gameVersion = '2.0.0',
    log = function(level, message) table.insert(h.logs, level .. ' ' .. message) end,
    send = function(req, cb)
      if req.url:find('/ingest/config?', 1, true) and not opts.config then cb(404, '{}', {}) return end
      table.insert(h.requests, { req = req, cb = cb })
    end,
    now = function() return h.clock end,
    time = function() return h.wall end,
    timeMs = function() return h.wall * 1000 end,
    storage = {
      read = function(n) return h.files[n] end,
      write = function(n, t) h.files[n] = t end,
      remove = function(n) h.files[n] = nil end,
      replace = function(n, t) h.replaced = h.replaced + 1; h.files[n] = t end,
    },
    randomHex = function(n) return string.rep('ab', n) end,
    platform = 'macOS', osName = 'macos',
    random = function() return 1 end,
    gzip = opts.gzip,
    device = opts.device,
    consent = opts.consent,
  })
  for _, name in ipairs({ 'flush_failed', 'events_flushed', 'tracking_disabled' }) do
    h.core:on(name, function(...) table.insert(h.events, { name, ... }) end)
  end
  function h.answer(path, status, body, headers)
    local r = table.remove(h.requests, 1)
    assert(r, 'expected a request to ' .. path .. ', but none was sent')
    assert(r.req.url:find(path, 1, true), 'expected ' .. path .. ', got ' .. r.req.url)
    r.cb(status, body and json.encode(body) or '', headers or {})
    return r.req
  end
  function h.boot(answer)
    h.core:start()
    h.answer('/api/v1/settings', 200, { trackingEnabled = true })
    local session = { token = 'tok', expiresIn = 3600, origin = ORIGIN_A }
    for k, v in pairs(answer or {}) do session[k] = v end
    return h.answer('/api/v1/session', 201, session)
  end
  function h.batch(req) return json.decode(req.body).events end
  function h.names(req)
    local out = {}
    for _, e in ipairs(h.batch(req)) do out[#out + 1] = e.event end
    return table.concat(out, ',')
  end
  function h.doc() local t = h.files[Core.queueFile(KEY)]; return t and json.decode(t) end
  function h.saved()
    local doc = h.doc()
    if not doc then return nil end
    local out = {}
    for _, g in ipairs(doc.groups) do for _, e in ipairs(g.events) do out[#out + 1] = e end end
    return out
  end
  function h.pendingNames()
    local out = {}
    for _, e in ipairs(h.core.pending) do out[#out + 1] = e.event end
    return table.concat(out, ',')
  end
  return h
end

local function record(n)
  local events = {}
  for i = 1, n do events[i] = { event = 'e' .. i, timestamp = 1800000000000 - 1000 + i, data = { rs_event_id = 'id' .. i } } end
  return events
end

return {
  -- ------------------------------------------------------------ delivery
  { 'the queue file is named by the 64-bit FNV-1a hash of the key', function()
    eq(Core.fnv1a64(''), 'cbf29ce484222325')
    eq(Core.fnv1a64('a'), 'af63dc4c8601ec8c')
    eq(Core.fnv1a64('gt_live_test'), '094acf328fe638e2')
    eq(Core.fnv1a64('gt_pub_é'), '853d257447c0bc87', 'over the UTF-8 bytes')
    eq(Core.queueFile('gt_live_test'), 'ravensight/queue-094acf328fe638e2.json')
  end },
  { 'events are saved with their session origin and replayed under it', function()
    local h = harness()
    h.boot({ signing = { algorithm = 'HMAC-SHA256', version = 1, secret = 's3cret-value', serverTime = 1800000000 } })
    h.core:track('pickup', { n = 1 })
    h.core:update()
    local doc = h.doc()
    eq(doc.version, 2)
    eq(#doc.groups, 1)
    eq(json.encode(doc.groups[1].origin), json.encode(ORIGIN_A), 'the origin as received')
    eq(#doc.groups[1].events, 2)
    assert(h.replaced > 0, 'written through the atomic replace')
    assert(not h.files[Core.queueFile(KEY)]:find('s3cret%-value'), 'the secret is never written')
    assert(not h.files[Core.queueFile(KEY)]:find('"tok"'), 'nor the session token')
    local ids = { doc.groups[1].events[1].data.rs_event_id, doc.groups[1].events[2].data.rs_event_id }
    local stamp = doc.groups[1].events[2].timestamp
    -- The process dies; the next launch opens another session.
    local two = harness({ files = h.files })
    two.boot({ origin = ORIGIN_B })
    local req = two.requests[1].req
    local batch = two.batch(req)
    eq(two.names(req), 'game_started,pickup,game_started')
    eq(json.encode(batch[1].origin), json.encode(ORIGIN_A), 'an earlier session carries its origin')
    eq(json.encode(batch[2].origin), json.encode(ORIGIN_A), 'on every event of the group')
    eq(batch[3].origin, nil, 'this session needs none')
    eq(batch[1].data.rs_event_id, ids[1]); eq(batch[2].data.rs_event_id, ids[2])
    eq(batch[2].timestamp, stamp, 'the original timestamp')
    for _, e in ipairs(batch) do
      for k in pairs(e) do assert(k == 'event' or k == 'data' or k == 'timestamp' or k == 'origin', 'unexpected wire field ' .. k) end
    end
    two.answer('/track/batch', 202, { accepted = 3 })
    eq(two.doc(), nil, 'delivered: the file is gone')
  end },
  { 'only a 2xx or a refusing 400 removes events, and the removal is saved first', function()
    local h = harness()
    h.boot()
    h.answer('/track/batch', 202)
    h.core:track('a', {}); h.core:track('b', {})
    h.core:update()
    h.core:flush()
    h.answer('/track/batch', 500)
    eq(#h.saved(), 2, 'a 5xx keeps them')
    h.clock = 10; h.core:update()
    h.answer('/track/batch', 429, { error = 'rate_limited' }, { ['retry-after'] = '5' })
    eq(#h.saved(), 2, 'a 429 keeps them')
    h.clock = 15; h.core:update()
    h.answer('/track/batch', 202)
    eq(h.saved(), nil, 'a 2xx removes them')
  end },
  { 'an unusable file is an empty queue; version 1 and the 0.5 file are read', function()
    for _, text in ipairs({ 'not json', '{"version":9,"groups":[]}', '[]', '{"version":2}' }) do
      local h = harness({ files = { [Core.queueFile(KEY)] = text } })
      h.boot()
      eq(h.names(h.requests[1].req), 'game_started', text)
    end
    local v1 = harness({ files = { [Core.queueFile(KEY)] = json.encode({ version = 1, groups = { { origin = ORIGIN_A, events = record(1) } } }) } })
    v1.boot({ origin = ORIGIN_B })
    local batch = v1.batch(v1.requests[1].req)
    eq(batch[1].event, 'e1'); eq(batch[1].origin, nil, 'a version 1 group has no origin')
    v1.core:update()
    eq(v1.doc().version, 2, 'the next write is version 2')
    local legacy = harness({ files = { [Core.LEGACY_QUEUE_FILE] = json.encode(record(2)) } })
    legacy.boot()
    eq(legacy.names(legacy.requests[1].req), 'e1,e2,game_started', 'the 0.5 queue is sent')
    eq(legacy.files[Core.LEGACY_QUEUE_FILE], nil, 'and its file removed')
  end },
  { 'events older than 89 days are dropped on load and the queue is capped at 500', function()
    local events = record(600)
    table.insert(events, 1, { event = 'ancient', timestamp = 1800000000000 - 90 * 86400000, data = {} })
    table.insert(events, 1, { event = 'old_seconds', timestamp = 1800000000 - 100 * 86400, data = {} })
    local h = harness({ files = { [Core.queueFile(KEY)] = json.encode({ version = 2, groups = { { origin = ORIGIN_A, events = events } } }) } })
    h.core:start()
    eq(#h.core.pending, 500)
    eq(h.core.pending[1].event, 'e101', 'the oldest go first')
    eq(h.core:getDeliveryStats().dropped_too_old, 2)
    eq(h.core:getDeliveryStats().dropped_overflow, 100)
    eq(#h.saved(), 500, 'the trimmed queue is saved')
  end },
  { 'opt-out and a reset identity delete the saved queue; a 403 keeps it', function()
    local h = harness()
    h.boot()
    h.core:track('a', {}); h.core:update()
    assert(h.doc())
    h.core:setTrackingEnabled(false)
    eq(h.doc(), nil, 'opt-out')
    local r = harness()
    r.boot()
    r.core:track('a', {}); r.core:update()
    r.core:resetDeviceId()
    eq(r.doc(), nil, 'reset')
    local k = harness()
    k.boot()
    k.core:track('c', {})
    -- Answered in the same frame, before update() wrote the queue.
    k.answer('/track/batch', 403, { error = 'public_key_inactive' })
    eq(k.core:isTrackingEnabled(), false, 'stops sending')
    local names = {}
    for _, e in ipairs(k.saved()) do names[#names + 1] = e.event end
    eq(table.concat(names, ','), 'game_started,c', 'kept for the next launch')
  end },
  { 'a 400 with index drops that event and resends the rest', function()
    local h = harness()
    h.boot()
    h.answer('/track/batch', 202)
    for i = 1, 3 do h.core:track('e' .. i, {}) end
    h.core:flush()
    h.answer('/track/batch', 400, { error = 'reserved_key', index = 1 })
    eq(h.names(h.requests[1].req), 'e1,e3')
    eq(h.core:getDeliveryStats().dropped_refused, 1)
  end },
  { 'batch_too_large halves, another 400 drops the request', function()
    local h = harness()
    h.boot()
    h.answer('/track/batch', 202)
    for i = 1, 4 do h.core:track('e' .. i, {}) end
    h.core:flush()
    h.answer('/track/batch', 400, { error = 'batch_too_large' })
    eq(h.names(h.requests[1].req), 'e1,e2')
    h.answer('/track/batch', 202); h.answer('/track/batch', 202)
    h.core:track('x', {}); h.core:track('y', {})
    h.core:flush()
    h.answer('/track/batch', 400, { error = 'invalid_json' })
    eq(#h.core.pending, 0)
    eq(h.core:getDeliveryStats().dropped_refused, 2)
  end },
  { 'gzip from 1,024 bytes; 415 resends plain once, then drops; 413 halves', function()
    local gz = function(t) return 'GZ' .. t end
    local h = harness({ gzip = gz })
    h.boot()
    local first = h.requests[1].req
    eq(first.headers['Content-Encoding'], nil, 'a small body is plain')
    h.answer('/track/batch', 202)
    h.core:track('big', { blob = string.rep('y', 2000) })
    h.core:flush()
    local req = h.requests[1].req
    eq(req.headers['Content-Encoding'], 'gzip')
    eq(req.body:sub(1, 2), 'GZ', 'compressed by deps.gzip')
    h.answer('/track/batch', 415)
    eq(h.requests[1].req.headers['Content-Encoding'], nil, 'resent uncompressed')
    h.answer('/track/batch', 415)
    eq(#h.core.pending, 0, 'then dropped')
    h.core:track('next', { blob = string.rep('z', 2000) }); h.core:flush()
    eq(h.requests[1].req.headers['Content-Encoding'], 'gzip', 'later batches compress again')
    h.answer('/track/batch', 202)
    for i = 1, 4 do h.core:track('e' .. i, {}) end
    h.core:flush()
    h.answer('/track/batch', 413)
    eq(#h.batch(h.requests[1].req), 2, 'a 413 halves')
    local none = harness()
    none.boot()
    none.answer('/track/batch', 202)
    none.core:track('big', { blob = string.rep('y', 2000) }); none.core:flush()
    eq(none.requests[1].req.headers['Content-Encoding'], nil, 'no gzip on the platform: plain')
  end },
  { 'the signing vectors pass', function()
    local v = vectors().signing
    for _, case in ipairs(v.header) do
      eq('v1=' .. Hmac.sign(v.secret, case.timestamp, case.body), case.header, case.name)
    end
    for _, case in ipairs(v.beacon) do
      eq(Hmac.sign(v.secret, case.t, case.inner), case.envelope.signed.sig, case.name)
    end
    eq(Hmac.sign(v.secret, 1767225600, '{"event":"game_started"}', Hmac.sha256), '03331575ba8750faafc921588376ae6489dc6b799737ed1aa52e15a289ce2ddd')
  end },
  { 'a signing session signs every batch with the server clock; a 401 reopens once', function()
    local h = harness({ gzip = function(t) return 'GZ' .. t end })
    h.boot({ signing = { algorithm = 'HMAC-SHA256', version = 1, secret = SECRET, serverTime = 1800000100 } })
    local req = h.requests[1].req
    eq(req.headers['X-Ravensight-Timestamp'], '1800000100')
    eq(req.headers['X-Ravensight-Signature'], 'v1=' .. Hmac.sign(SECRET, 1800000100, req.body))
    h.answer('/track/batch', 202)
    h.core:track('big', { blob = string.rep('y', 2000) }); h.core:flush()
    local big = h.requests[1].req
    eq(big.headers['X-Ravensight-Signature'], 'v1=' .. Hmac.sign(SECRET, 1800000100, big.body:sub(3)), 'over the uncompressed body')
    h.answer('/track/batch', 401, { error = 'signature_expired' })
    h.answer('/api/v1/session', 201, { token = 't2', expiresIn = 3600, origin = ORIGIN_B })
    local again = h.requests[1].req
    eq(again.headers['X-Ravensight-Signature'], nil, 'a session with no signing sends none')
    h.answer('/track/batch', 401, { error = 'invalid_session' })
    eq(#h.requests, 0, 'a second 401 in a row waits')
    assert(h.core.retryAt, 'for the backoff')
  end },
  { 'flush cuts a backoff short but never a Retry-After; 503 with Retry-After waits', function()
    local h = harness()
    h.boot()
    h.answer('/track/batch', 500)
    h.core:flush()
    eq(#h.requests, 1, 'an explicit flush cuts the backoff')
    h.answer('/track/batch', 503, { error = 'storage_unavailable' }, { ['retry-after'] = '30' })
    eq(h.core.retryAt, 30)
    h.core:flush()
    eq(#h.requests, 0, 'Retry-After holds')
    h.clock = 30; h.core:update()
    eq(#h.requests, 1)
  end },
  { 'event size vectors: the local 8 KB check agrees with the server', function()
    for _, case in ipairs(vectors().anyKeyEventSize.cases) do
      local data = expand(case.data)
      eq(Core.eventBytes(data) > Core.MAX_EVENT_BYTES, case.expect == 'event_too_large', case.name)
    end
  end },
  { 'the session carries the device fields, cleaned', function()
    local h = harness({ device = { model = '  Pixel\7 7 ', osVersion = '', gpu = string.rep('G', 200) } })
    h.core:start()
    h.answer('/api/v1/settings', 200, { trackingEnabled = true })
    local body = json.decode(h.requests[1].req.body)
    eq(body.device.model, 'Pixel 7'); eq(body.device.osVersion, nil); eq(#body.device.gpu, 128)
    local none = harness()
    none.core:start()
    none.answer('/api/v1/settings', 200, { trackingEnabled = true })
    eq(json.decode(none.requests[1].req.body).device, nil, 'nothing known: no device object')
  end },
  { 'a full queue evicts automatic errors first and queues gameplay ahead of them', function()
    local h = harness()
    h.core.maxQueueSize = 4
    h.core:track('a', {})
    h.core:track('crash', { rs_kind = 'error', rs_severity = 'error', rs_message = 'x', rs_source = 'uncaught' })
    h.core:track('b', {})
    eq(h.pendingNames(), 'a,b,crash', 'gameplay goes ahead of a queued automatic error')
    h.core:track('manual', { rs_kind = 'error', rs_severity = 'error', rs_message = 'y', rs_source = 'manual' })
    eq(h.pendingNames(), 'a,b,manual,crash', 'a manual error is gameplay')
    h.core:track('c', {})
    eq(h.pendingNames(), 'a,b,manual,c', 'full: the automatic error is evicted, not the oldest')
    h.core:track('crash2', { rs_kind = 'error', rs_severity = 'error', rs_message = 'z', rs_source = 'log' })
    eq(h.pendingNames(), 'a,b,manual,c', 'an automatic error never evicts gameplay')
    h.core:track('d', {})
    eq(h.pendingNames(), 'b,manual,c,d', 'with no automatic error, the oldest goes')
    eq(h.core:getDeliveryStats().dropped_overflow, 3)
  end },
  { 'a 413 on a batch is split like a 400', function()
    local h = harness()
    h.boot()
    h.answer('/track/batch', 202)
    for i = 1, 4 do h.core:track('e' .. i, {}) end
    h.core:flush()
    h.answer('/track/batch', 413, { error = 'payload_too_large' })
    eq(h.names(h.requests[1].req), 'e1,e2')
    h.answer('/track/batch', 413)
    eq(h.names(h.requests[1].req), 'e1')
  end },
  -- ------------------------------------------- error queue rules (all SDKs)
  { 'error rule 1: gameplay, a game error included, goes before captures, also after a load', function()
    local cap = { rs_kind = 'error', rs_severity = 'error', rs_message = 'x', rs_source = 'uncaught' }
    local h = harness()
    h.core:start()
    h.core:track('a', {})
    h.core:track('capture', cap)
    h.core:track('own_error', { rs_kind = 'error', rs_severity = 'error', rs_message = 'game', rs_source = 'manual' })
    h.core:track('b', {})
    eq(h.pendingNames(), 'a,own_error,b,capture')
    local files = { [Core.queueFile(KEY)] = json.encode({ version = 2, groups = { { events = {
      { event = 'old_capture', timestamp = 1800000000000 - 10, data = cap },
      { event = 'old_play', timestamp = 1800000000000 - 5, data = {} } } } } }) }
    local two = harness({ files = files })
    two.boot()
    eq(two.names(two.requests[1].req), 'old_play,game_started,old_capture', 'gameplay before captures within the flush')
  end },
  { 'error rule 2: a capture evicts the oldest capture, never gameplay', function()
    local cap = function(m) return { rs_kind = 'error', rs_severity = 'error', rs_message = m, rs_source = 'log' } end
    local h = harness()
    h.core.maxQueueSize = 3
    h.core:track('a', {})
    h.core:track('c1', cap('1'))
    h.core:track('c2', cap('2'))
    h.core:track('c3', cap('3'))
    eq(h.pendingNames(), 'a,c2,c3', 'the oldest capture went')
    h.core:track('b', {})
    h.core:track('c', {})
    eq(h.pendingNames(), 'a,b,c', 'gameplay as before, captures first')
    h.core:track('c4', cap('4'))
    eq(h.pendingNames(), 'a,b,c', 'with no capture queued the incoming capture is dropped')
  end },
  { 'error rule 3: rs_trail never reaches the queue file; opt-out and reset delete persisted captures', function()
    local h = harness()
    h.boot()
    h.core:track('capture', { rs_kind = 'error', rs_severity = 'error', rs_message = 'x', rs_source = 'crash', rs_trail = '+0 info entered cave' })
    h.core:update()
    local text = h.files[Core.queueFile(KEY)]
    assert(text:find('"capture"'), 'the capture is persisted')
    assert(not text:find('rs_trail') and not text:find('entered cave'), 'its trail is not')
    eq(h.core.pending[#h.core.pending].data.rs_trail, '+0 info entered cave', 'the trail stays in memory')
    h.core:setTrackingEnabled(false)
    eq(h.files[Core.queueFile(KEY)], nil, 'opt-out deletes persisted captures')
    local r = harness()
    r.boot()
    r.core:track('capture', { rs_kind = 'error', rs_severity = 'error', rs_message = 'x', rs_source = 'crash' })
    r.core:update()
    assert(r.files[Core.queueFile(KEY)])
    r.core:resetDeviceId()
    eq(r.files[Core.queueFile(KEY)], nil, 'a device id reset deletes persisted captures')
  end },
  { 'error rule: nothing in the batch in flight is ever evicted', function()
    local cap = function(m) return { rs_kind = 'error', rs_severity = 'error', rs_message = m, rs_source = 'log' } end
    local h = harness()
    h.boot()
    h.answer('/track/batch', 202)
    h.core.maxQueueSize = 4
    h.core:track('a', {})
    h.core:track('c1', cap('1'))
    h.core:flush()
    eq(h.names(h.requests[1].req), 'a,c1', 'a batch with a capture in flight')
    h.core:track('b', {})
    h.core:track('c2', cap('2'))
    h.core:track('c3', cap('3'))
    eq(h.pendingNames(), 'a,c1,b,c3', 'the capture outside the flight went, not the one in it')
    h.core:track('c', {})
    eq(h.pendingNames(), 'a,c1,b,c', 'gameplay evicts the capture outside the flight')
    h.core:track('d', {})
    eq(h.pendingNames(), 'a,c1,c,d', 'then the oldest outside the flight')
    h.answer('/track/batch', 202)
    eq(h.pendingNames(), 'c,d', 'the answer removes exactly the batch it sent')
    local full = harness()
    full.boot()
    full.answer('/track/batch', 202)
    full.core.maxQueueSize = 2
    full.core:track('x', cap('x'))
    full.core:track('y', {})
    full.core:flush()
    full.core:track('z', {})
    full.core:track('w', cap('w'))
    eq(full.pendingNames(), 'y,x', 'all in flight: the incoming events are dropped')
  end },
  { 'the queue file is kept out of backups on macOS; elsewhere the helper says it could not', function()
    for name in pairs(package.loaded) do
      if name == 'ravensight' or name:match('^ravensight%.') then package.loaded[name] = nil end
    end
    local rs = require('ravensight')
    local path = os.tmpname()
    local f = assert(io.open(path, 'wb')); f:write('{}'); f:close()
    local okFfi, ffi = pcall(require, 'ffi')
    local done = rs._excludeFromBackup(path)
    if okFfi and ffi.os == 'OSX' then
      assert(done, 'set on macOS')
      local pipe = io.popen('tmutil isexcluded ' .. path)
      local out = pipe:read('*a'); pipe:close()
      assert(out:find('%[Excluded%]'), 'Time Machine reads it as excluded: ' .. out)
    else
      eq(done, nil, 'no such call here')
    end
    os.remove(path)
  end },
  { 'a failed exclusion is retried once, then one warning with no file contents', function()
    for name in pairs(package.loaded) do
      if name == 'ravensight' or name:match('^ravensight%.') then package.loaded[name] = nil end
    end
    local rs = require('ravensight')
    local dir = os.tmpname(); os.remove(dir); os.execute('mkdir -p "' .. dir .. '"')
    local printed = {}
    local oldPrint = print
    print = function(line) printed[#printed + 1] = tostring(line) end
    _G.love = { filesystem = {
      getSaveDirectory = function() return dir end,
      createDirectory = function(n) os.execute('mkdir -p "' .. dir .. '/' .. n .. '"') return true end,
      getInfo = function(n) local f = io.open(dir .. '/' .. n, 'rb'); if f then f:close() return {} end end,
      read = function(n) local f = io.open(dir .. '/' .. n, 'rb'); local t = f:read('*a'); f:close(); return t end,
      write = function(n, t) local f = io.open(dir .. '/' .. n, 'wb'); if not f then return false end f:write(t); f:close(); return true end,
      remove = function(n) return os.remove(dir .. '/' .. n) ~= nil end,
    } }
    local calls = 0
    rs._excludeFromBackup = function() calls = calls + 1 return false end
    assert(rs._storage.replace('ravensight/queue-x.json', '{"secret stamp":"o1.zzz"}'))
    print = oldPrint
    eq(calls, 2, 'tried twice')
    eq(#printed, 1, 'one warning')
    assert(printed[1]:find('out of backups'), printed[1])
    assert(not printed[1]:find('o1.zzz') and not printed[1]:find('stamp'), 'no file contents in the warning')
    calls = 0
    rs._excludeFromBackup = function() calls = calls + 1 return calls == 2 end
    rs._storage.replace('ravensight/queue-x.json', '{}')
    eq(calls, 2, 'a retry that succeeds')
    calls = 0
    rs._excludeFromBackup = function() calls = calls + 1 return nil end
    rs._storage.replace('ravensight/queue-x.json', '{}')
    eq(calls, 1, 'no retry where there is no such call')
    -- A rename that fails (a folder sits where the file goes) leaves no
    -- temporary file behind.
    os.execute('mkdir -p "' .. dir .. '/ravensight/queue-y.json/inner"')
    rs._storage.replace('ravensight/queue-y.json', '{}')
    local tmp = io.open(dir .. '/ravensight/queue-y.json.tmp', 'rb')
    if tmp then tmp:close() end
    assert(not tmp, 'a failed rename deletes its temporary file')
    _G.love = nil
    os.execute('rm -rf "' .. dir .. '"')
  end },
  { 'the queue file and a leftover temporary file go on every delete; load applies the exclusion', function()
    local h = harness()
    h.boot()
    h.core:track('a', {})
    h.core:update()
    local name = Core.queueFile(KEY)
    h.files[name .. '.tmp'] = '{"partial'
    h.core:setTrackingEnabled(false)
    eq(h.files[name], nil); eq(h.files[name .. '.tmp'], nil, 'opt-out')
    h.core:setTrackingEnabled(true)
    h.core:track('b', {}); h.core:update()
    assert(h.files[name], 'queued again')
    h.files[name .. '.tmp'] = '{"partial'
    h.core:resetDeviceId()
    eq(h.files[name .. '.tmp'], nil, 'a device id reset')
    local e = harness()
    e.boot()
    e.files[name .. '.tmp'] = '{"partial'
    e.answer('/track/batch', 202)
    eq(e.files[name], nil); eq(e.files[name .. '.tmp'], nil, 'an emptied queue')
    -- Reading an existing queue file applies the exclusion to it.
    local files = { [name] = json.encode({ version = 2, groups = { { events = record(1) } } }) }
    local l = harness({ files = files })
    local seen = {}
    l.core.storage.exclude = function(n) seen[#seen + 1] = n end
    l.core:start()
    eq(seen[1], name, 'the existing file is excluded on load')
  end },
  -- ---------------------------------------------------- ads and attribution
  { 'trackAdRevenue sends exactly the seven keys, micros as a digit string', function()
    local name, props = Typed.ad('admob', 'rewarded', 'shown', { placement = 'level_end', revenueMicros = '1500', currency = 'USD' })
    eq(name, 'rs_ad')
    local keys = {}
    for k in pairs(props) do keys[#keys + 1] = k end
    table.sort(keys)
    eq(table.concat(keys, ','), 'rs_ad_format,rs_ad_network,rs_ad_placement,rs_ad_result,rs_currency,rs_kind,rs_revenue_micros')
    eq(props.rs_revenue_micros, '1500'); eq(props.rs_kind, 'ad')
    local _, p2 = Typed.ad('unity', 'banner', 'shown', { revenueMicros = 2500, currency = 'eur' })
    eq(p2.rs_revenue_micros, '2500'); eq(p2.rs_currency, 'EUR')
    local _, click = Typed.ad('applovin', 'interstitial', 'clicked', { placement = '' })
    eq(click.rs_revenue_micros, nil); eq(click.rs_ad_placement, nil, 'an empty placement is left out')
  end },
  { 'malformed ad events are refused locally', function()
    eq(Typed.ad('admob', 'rewarded', 'shown', { revenueMicros = '1500' }), nil, 'revenue without a currency')
    eq(Typed.ad('admob', 'rewarded', 'shown', { revenueMicros = 0.0015, currency = 'USD' }), nil, 'a fraction')
    eq(Typed.ad('admob', 'rewarded', 'shown', { revenueMicros = '0.0015', currency = 'USD' }), nil, 'decimal text')
    eq(Typed.ad('admob', 'rewarded', 'clicked', { revenueMicros = '10', currency = 'USD' }), nil, 'revenue on a click')
    eq(Typed.ad('admob', 'video', 'shown'), nil, 'a format')
    eq(Typed.ad('', 'banner', 'shown'), nil, 'an empty network')
    eq(Typed.ad('admob', 'banner', 'shown', { placement = string.rep('p', 101) }), nil, 'a long placement')
    eq(Typed.ad('admob', 'banner', 'shown', { currency = 'USD' }), nil, 'a currency alone')
  end },
  { 'micros without a float multiply', function()
    local cases = { ['0.0015'] = '1500', ['1.23456789'] = '1234568', ['1.2345675'] = '1234568', ['1.2345674'] = '1234567',
      ['1.9999995'] = '2000000', ['9.9999999'] = '10000000', ['0.0000005'] = '1', ['12'] = '12000000', ['.5'] = '500000', ['0'] = '0' }
    for input, out in pairs(cases) do eq(Typed.microsFromDecimalString(input), out, input) end
    for _, bad in ipairs({ '', 'abc', '-1', '1e5', '1.2.3', ' ', '999999999999.9999999' }) do eq(Typed.microsFromDecimalString(bad), nil, bad) end
    eq(Typed.microsFromRevenue(0.0015), '1500')
    eq(Typed.microsFromRevenue(1.23456789), '1234568')
    eq(Typed.microsFromRevenue(-1), nil); eq(Typed.microsFromRevenue(math.huge), nil); eq(Typed.microsFromRevenue(0 / 0), nil)
  end },
  { 'setAttribution is sent once per install, across restarts, until a reset', function()
    local h = harness()
    h.boot()
    assert(h.core:setAttribution({ source = 'store_referrer', network = 'newsletter', campaign = 'spring', adset = '', touchTime = 1767225600000 }))
    local e = h.core.pending[#h.core.pending]
    eq(e.event, 'rs_attribution'); eq(e.data.rs_attr_source, 'store_referrer'); eq(e.data.rs_campaign, 'spring')
    eq(e.data.rs_adset, nil); eq(e.data.rs_touch_time, 1767225600000); eq(e.data.rs_attr_network, 'newsletter')
    eq(h.core:setAttribution({ source = 'organic' }), false)
    local two = harness({ files = h.files })
    two.boot()
    eq(two.core:setAttribution({ source = 'organic' }), false, 'not after a restart')
    two.core:resetDeviceId()
    assert(two.core:setAttribution({ source = 'organic' }), 'a reset identity is a new install')
    local three = harness()
    three.boot()
    eq(three.core:setAttribution({ source = '' }), false, 'a source is required')
  end },
  -- -------------------------------------------------------------- exposure
  { 'exposure: a fetch alone tags nothing; the first read tags later events and sends rs_exposure', function()
    local doc = { values = { speed = 3 }, experiments = { { key = 'difficulty', variant = 'easy' } }, etag = '"' .. string.rep('a', 64) .. '"' }
    local h = harness({ config = true })
    h.boot()
    h.answer('/track/batch', 202)
    h.answer('/ingest/config', 200, doc)
    h.core:track('before_read', {})
    eq(h.core.pending[#h.core.pending].data.rs_exp_difficulty, nil, 'no tag after a fetch')
    h.core:getConfig('speed', 0)
    h.core:getConfig('speed', 0)
    h.core:track('after_read', {})
    local names, last = {}, h.core.pending
    for _, e in ipairs(last) do names[#names + 1] = e.event end
    eq(table.concat(names, ','), 'before_read,rs_exposure,after_read', 'one rs_exposure')
    eq(last[2].data.rs_exp_difficulty, 'easy', 'rs_exposure carries the tags')
    eq(last[3].data.rs_exp_difficulty, 'easy', 'later events too')
    eq(last[1].data.rs_exp_difficulty, nil, 'earlier events stay untagged')
    -- A stopped experiment is not tagged after the next fetch.
    h.core:fetchConfig()
    h.answer('/ingest/config', 200, { values = { speed = 3 }, experiments = {}, etag = '"' .. string.rep('b', 64) .. '"' })
    h.core:track('after_stop', {})
    eq(h.core.pending[#h.core.pending].data.rs_exp_difficulty, nil)
  end },
  { 'exposure: a new launch starts untagged, and a queued event keeps its tag', function()
    local doc = { values = { speed = 3 }, experiments = { { key = 'difficulty', variant = 'easy' } }, etag = '"' .. string.rep('a', 64) .. '"' }
    local h = harness({ config = true })
    h.boot()
    h.answer('/track/batch', 202)
    h.answer('/ingest/config', 200, doc)
    h.core:getConfig('speed', 0)
    h.core:track('offline_play', {})
    h.core:update()
    local two = harness({ files = h.files, config = true })
    two.boot({ origin = ORIGIN_B })
    local played
    for _, e in ipairs(two.batch(two.requests[1].req)) do if e.event == 'offline_play' then played = e end end
    eq(played.data.rs_exp_difficulty, 'easy', 'the tag it was queued with')
    two.answer('/track/batch', 202)
    two.answer('/ingest/config', 200, doc)
    two.core:track('new_launch', {})
    eq(two.core.pending[#two.core.pending].data.rs_exp_difficulty, nil, 'a new session starts untagged')
  end },
  { 'web: the first config read after an answer is passed to the page', function()
    local lines = {}
    local w = Web.new({ print = function(l) lines[#lines + 1] = l end, storage = { read = function() end, write = function() end, remove = function() end }, readConfig = function() return nil end })
    w:start()
    w:getConfig('speed', 1); w:getConfig('speed', 1)
    local reads = 0
    for _, l in ipairs(lines) do if l:find('"op":"config_read"', 1, true) then reads = reads + 1 end end
    eq(reads, 1, 'once per config answer')
  end },
}
