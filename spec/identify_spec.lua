-- identify(accountId) and resetIdentity() against the binding vectors
-- (spec/identify-vectors.json, a copy of the server's docs/identify), with
-- the core's fake world: a clock, a network the test answers and storage
-- that is a plain table. Sessions answer the tokens S1, S2, ... in order.

local Core = require('ravensight.core')
local Hmac = require('ravensight.hmac')
local json = require('ravensight.json')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local function readVectors()
  local f = assert(io.open('spec/identify-vectors.json', 'rb'))
  local text = f:read('*a')
  f:close()
  return json.decode(text)
end
local V = readVectors()
local SALT = V.salt
local SEQ = V.sequence

--- Deep equality for plain tables of strings, numbers and booleans.
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function show(v)
  return type(v) == 'table' and json.encode(v) or tostring(v)
end

local function same_as(a, b, msg)
  assert(same(a, b), (msg or '') .. ' expected ' .. show(b) .. ', got ' .. show(a))
end

-- One world shared by every client a test makes, so a relaunch reads the
-- files the last client wrote and session tokens keep counting.
local function world(opts)
  opts = opts or {}
  local w = { files = {}, requests = {}, sessions = 0, salt = opts.salt, wall = 1800000000, clock = 0, logs = {} }
  function w.client(extra)
    extra = extra or {}
    local core = Core.new({
      apiUrl = 'https://api.test',
      ingestKey = extra.ingestKey or 'gt_live_k',
      send = function(req, cb) table.insert(w.requests, { req = req, cb = cb, answered = false }) end,
      now = function() return w.clock end,
      time = function() return w.wall end,
      storage = {
        read = function(n) return w.files[n] end,
        write = function(n, t) w.files[n] = t end,
        remove = function(n) w.files[n] = nil end,
      },
      randomHex = function(n)
        w.hexCounter = (w.hexCounter or 0) + 1
        return string.format('%0' .. (n * 2) .. 'x', w.hexCounter)
      end,
      platform = 'macOS',
      osName = 'macos',
      consent = extra.consent,
      playtest = extra.playtest,
      log = function(level, message) table.insert(w.logs, level .. ' ' .. message) end,
      random = function() return 1 end,
    })
    return core
  end
  --- Answers every open request: settings on, sessions S1, S2, ... with the
  --- world's salt, identify from `answers` ({status, body}) then 200.
  function w.serve(answers)
    answers = answers or {}
    for _ = 1, 100 do
      local r
      for _, q in ipairs(w.requests) do if not q.answered then r = q break end end
      if not r then return end
      r.answered = true
      local url = r.req.url
      if url:find('/api/v1/settings', 1, true) then
        r.cb(200, json.encode({ trackingEnabled = true }), {})
      elseif url:find('/api/v1/session', 1, true) then
        w.sessions = w.sessions + 1
        local created = { token = 'S' .. w.sessions, expiresIn = 86400 }
        if w.salt then created.identify = { salt = w.salt } end
        r.cb(201, json.encode(created), {})
      elseif url:find('/api/v1/identify', 1, true) then
        local a = table.remove(answers, 1)
        if a then
          r.cb(a[1], a[2] and json.encode(a[2]) or '', {})
        else
          r.cb(200, json.encode({ playerId = 'px_test', linked = true, verified = false, ['repeat'] = false }), {})
        end
      elseif url:find('/api/v1/track/batch', 1, true) then
        r.cb(202, json.encode({ accepted = 1 }), {})
      else
        r.cb(404, '{}', {})
      end
    end
  end
  --- The identify requests from index `from` (1-based count already seen).
  function w.sends(from)
    local out = {}
    for _, q in ipairs(w.requests) do
      if q.req.url:find('/api/v1/identify', 1, true) then
        out[#out + 1] = { session = q.req.headers['X-Session-Token'], accountHash = json.decode(q.req.body).accountHash }
      end
    end
    local tail = {}
    for i = (from or 0) + 1, #out do tail[#tail + 1] = out[i] end
    return tail
  end
  function w.count() return #w.sends(0) end
  function w.stored()
    local text = w.files[Core.IDENTITY_FILE]
    return text and json.decode(text) or nil
  end
  --- The session ends; the next event opens a new one.
  function w.nextSession(core, answers)
    w.wall = w.wall + 90000
    core:track('tick', {})
    core:flush()
    w.serve(answers)
  end
  return w
end

local function started(w, extra)
  local core = w.client(extra)
  core:start()
  w.serve()
  return core
end

return {
  { 'every accept vector, with the file salt, is sent as its wire and stored with the salt', function()
    eq(V.version, 2, 'vectors version 2')
    for _, c in ipairs(V.accept) do
      local w = world({ salt = SALT })
      local core = started(w)
      eq(core:identify(c.accountId), true, c.note)
      w.serve()
      local sends = w.sends()
      eq(#sends, 1, c.note)
      eq(sends[1].accountHash, c.wire, c.note)
      same_as(w.stored(), { salt = SALT, accountHash = c.wire }, c.note)
      eq(core:isIdentified(), true, c.note)
    end
  end },

  { 'the pure Lua HMAC matches every wire, including one longer than the block', function()
    for _, c in ipairs(V.accept) do
      local id = type(c.accountId) == 'number' and string.format('%d', c.accountId) or c.accountId
      eq(Hmac.hex(SALT, id), c.wire, c.note)
    end
    local found = false
    for _, c in ipairs(V.accept) do if #tostring(c.accountId) > 64 then found = true end end
    assert(found, 'a vector longer than the 64-byte block')
  end },

  { 'salts_differ: one account under two salts gives the two wires', function()
    local d = V.salts_differ
    eq(Hmac.hex(d.salt_a, d.accountId), d.wire_a)
    eq(Hmac.hex(d.salt_b, d.accountId), d.wire_b)
    assert(d.wire_a ~= d.wire_b)
  end },

  { 'every refuse vector is refused with nothing sent, nothing stored and the device id kept', function()
    for _, c in ipairs(V.refuse) do
      for _, beforeSession in ipairs({ false, true }) do
        local w = world({ salt = SALT })
        local core = w.client()
        core:start()
        if not beforeSession then w.serve() end
        local device = core.deviceId
        local ok, reason = core:identify(c.accountId)
        eq(ok, false, c.note)
        eq(reason, c.reason, c.note)
        w.serve()
        eq(w.count(), 0, c.note)
        eq(w.stored(), nil, c.note)
        eq(core.deviceId, device, c.note)
        eq(core:isIdentified(), false, c.note)
      end
    end
  end },

  { 'a refusal while identified keeps the identity and the device and sends nothing', function()
    local w = world({ salt = SALT })
    local core = started(w)
    core:identify('u1')
    w.serve()
    local before, device = w.files[Core.IDENTITY_FILE], core.deviceId
    for _, c in ipairs(V.refuse) do eq(core:identify(c.accountId), false, c.note) end
    w.serve()
    eq(w.count(), 1)
    eq(w.files[Core.IDENTITY_FILE], before)
    eq(core.deviceId, device)
  end },

  { 'tables, booleans, functions, NaN, infinities and huge numbers are not_text', function()
    for _, value in ipairs({ {}, true, false, print, 0 / 0, math.huge, -math.huge, 2 ^ 60, 0.5 }) do
      local ok, reason = Core.identifyRefusal(value)
      eq(ok, nil, tostring(value)); eq(reason, 'not_text', tostring(value))
    end
    eq(Core.identifyText(12345), '12345')
    eq(Core.identifyText(-7), '-7')
  end },

  { 'the contract sequence holds: salt present, salt changed, salt missing', function()
    local w = world({ salt = SALT })
    local core, from, device

    -- 0: key and consent; identify("u1") before any session opens.
    core = w.client()
    core:start()
    device = core.deviceId
    eq(core:identify('u1'), true, SEQ[1].step)
    same_as(w.sends(), SEQ[1].expect.sends, SEQ[1].step)
    eq(w.stored(), nil, SEQ[1].step)
    eq(core:isIdentified(), SEQ[1].expect.held_in_memory, SEQ[1].step)
    for name, text in pairs(w.files) do assert(not text:find('u1', 1, true), 'the raw id is in no file: ' .. name) end

    -- 1: S1 opens with the salt.
    w.serve()
    same_as(w.sends(), SEQ[2].expect.sends, SEQ[2].step)
    same_as(w.stored(), SEQ[2].expect.stored, SEQ[2].step)

    -- 2: the same account again in S1.
    from, device = w.count(), core.deviceId
    core:identify('u1')
    w.serve()
    same_as(w.sends(from), SEQ[3].expect.sends, SEQ[3].step)
    eq(core.deviceId ~= device, SEQ[3].expect.device_changed, SEQ[3].step)

    -- 3: relaunch, S2 opens with the same salt.
    core = w.client()
    core:start()
    eq(core:isIdentified(), true, 'read back')
    from = w.count()
    w.serve()
    same_as(w.sends(from), SEQ[4].expect.sends, SEQ[4].step)

    -- 4: an email is refused.
    from, device = w.count(), core.deviceId
    local ok, reason = core:identify('player@example.com')
    eq(ok, false, SEQ[5].step); eq(reason, SEQ[5].expect.refused, SEQ[5].step)
    w.serve()
    same_as(w.sends(from), SEQ[5].expect.sends, SEQ[5].step)
    same_as(w.stored(), SEQ[5].expect.stored, SEQ[5].step)
    eq(core.deviceId ~= device, SEQ[5].expect.device_changed, SEQ[5].step)

    -- 5: another account: a fresh device and session S3.
    from, device = w.count(), core.deviceId
    core:identify('u2')
    w.serve()
    same_as(w.sends(from), SEQ[6].expect.sends, SEQ[6].step)
    same_as(w.stored(), SEQ[6].expect.stored, SEQ[6].step)
    eq(core.deviceId ~= device, SEQ[6].expect.device_changed, SEQ[6].step)
    eq(core.sessionToken, SEQ[6].expect.new_session, SEQ[6].step)
    eq(w.files[Core.DEVICE_ID_FILE], core.deviceId, 'the new device id is saved')

    -- 6: resetIdentity(): a fresh device, nothing sent; its session is S4.
    from, device = w.count(), core.deviceId
    core:resetIdentity()
    core:track('after_reset', {})
    core:flush()
    w.serve()
    same_as(w.sends(from), SEQ[7].expect.sends, SEQ[7].step)
    eq(w.stored(), nil, SEQ[7].step)
    eq(core.deviceId ~= device, SEQ[7].expect.device_changed, SEQ[7].step)
    eq(core.sessionToken, SEQ[7].expect.new_session, SEQ[7].step)
    eq(core:isIdentified(), false, SEQ[7].step)

    -- 7: reset again with nothing stored.
    from, device = w.count(), core.deviceId
    core:resetIdentity()
    w.serve()
    same_as(w.sends(from), SEQ[8].expect.sends, SEQ[8].step)
    eq(w.stored(), nil, SEQ[8].step)
    eq(core.deviceId ~= device, SEQ[8].expect.device_changed, SEQ[8].step)

    -- 8: identify("u3"), answered needs_funds: kept, no loop.
    from = w.count()
    core:identify('u3')
    w.serve({ { 429, { error = 'quota_exceeded', reason = 'needs_funds' } } })
    same_as(w.sends(from), SEQ[9].expect.sends, SEQ[9].step)
    same_as(w.stored(), SEQ[9].expect.stored, SEQ[9].step)
    core:identify('u3')
    w.serve()
    eq(w.count(), from + 1, 'never in a loop')

    -- 9: relaunch; S5 answers a different salt: deleted, never sent.
    w.salt = V.salts_differ.salt_b
    core = w.client()
    core:start()
    from = w.count()
    w.serve()
    eq(core.sessionToken, 'S5')
    same_as(w.sends(from), SEQ[10].expect.sends, SEQ[10].step)
    eq(w.stored(), nil, SEQ[10].step)
    eq(core:isIdentified(), false, SEQ[10].step)

    -- 10: identify("u4"); the session answer has no salt.
    w.salt = nil
    core = w.client()
    core:start()
    from = w.count()
    core:identify('u4')
    w.serve()
    same_as(w.sends(from), SEQ[11].expect.sends, SEQ[11].step)
    eq(w.stored(), nil, SEQ[11].step)
    eq(core:isIdentified(), false, 'the held id is dropped')
    eq(core:identify('u4'), true, 'still valid')
    w.serve()
    eq(w.count(), from, 'unavailable for the rest of the launch')

    -- 11: opt out.
    core:setTrackingEnabled(false)
    w.serve()
    same_as(w.sends(from), SEQ[12].expect.sends, SEQ[12].step)
    eq(w.stored(), nil, SEQ[12].step)
  end },

  { 'needs_funds, identify_limited, rate limits, 409s, 5xx and offline retry at the next session only', function()
    local answers = {
      { 429, { error = 'quota_exceeded', reason = 'needs_funds' } },
      { 429, { error = 'identify_limited' } },
      { 429, { error = 'rate_limited' } },
      { 409, { error = 'session_taken' } },
      { 409, { error = 'synthetic_session' } },
      { 503, nil },
      { 500, { error = 'internal' } },
      { 0, nil },
    }
    for _, a in ipairs(answers) do
      local w = world({ salt = SALT })
      local core = started(w)
      core:identify('u1')
      w.serve({ a })
      core:identify('u1')
      w.serve()
      eq(w.count(), 1, 'no retry in the session: ' .. tostring(a[1]))
      assert(w.stored(), 'kept: ' .. tostring(a[1]))
      w.nextSession(core)
      eq(w.count(), 2, 'again at the next session: ' .. tostring(a[1]))
      eq(w.sends()[2].session, core.sessionToken)
    end
  end },

  { 'a 404 or invalid_account_hash is not retried this launch; the next launch tries again', function()
    for _, a in ipairs({ { 404, { error = 'not_found' } }, { 400, { error = 'invalid_account_hash' } } }) do
      local w = world({ salt = SALT })
      local core = started(w)
      core:identify('u1')
      w.serve({ a })
      w.nextSession(core)
      core:resetDeviceId()
      core:track('b', {})
      core:flush()
      w.serve()
      eq(w.count(), 1, 'not retried: ' .. a[1])
      assert(w.stored(), 'kept')
      local next = started(w)
      eq(w.count(), 2, 'the next launch tries again')
      assert(next)
    end
  end },

  { 'a 400 no_session identifies again at the next session, once', function()
    local w = world({ salt = SALT })
    local core = started(w)
    core:identify('u1')
    w.serve({ { 400, { error = 'no_session' } } })
    eq(w.count(), 1)
    w.nextSession(core, { { 400, { error = 'no_session' } } })
    eq(w.count(), 2, 'again once')
    w.nextSession(core)
    eq(w.count(), 2, 'twice in a row ends it this launch')
  end },

  { 'resetDeviceId alone keeps the identity and the next session identifies again', function()
    local w = world({ salt = SALT })
    local core = started(w)
    core:identify('u1')
    w.serve()
    local stored = w.files[Core.IDENTITY_FILE]
    core:resetDeviceId()
    eq(w.files[Core.IDENTITY_FILE], stored)
    eq(core:isIdentified(), true)
    core:track('a', {})
    core:flush()
    w.serve()
    eq(w.count(), 2)
  end },

  { 'the request carries the key, the session token and exactly { accountHash }', function()
    local w = world({ salt = SALT })
    local core = started(w)
    core:identify('12345')
    local req
    for _, q in ipairs(w.requests) do if q.req.url:find('/identify', 1, true) then req = q.req end end
    assert(req, 'sent')
    eq(req.method, 'POST')
    eq(req.url, 'https://api.test/api/v1/identify')
    eq(req.headers['X-API-Key'], 'gt_live_k')
    eq(req.headers['X-Session-Token'], core.sessionToken)
    eq(req.body, '{"accountHash":"' .. V.accept[1].wire .. '"}')
    assert(not req.body:find(core.deviceId, 1, true), 'no device id')
  end },

  { 'identify never enters the queue or the saved queue, and never holds back events', function()
    local w = world({ salt = SALT })
    local core = started(w)
    core:identify('u1')
    eq(#core.pending, 0, 'nothing queued')
    core:track('a', {})
    core:flush()
    local batch = false
    for _, q in ipairs(w.requests) do
      if not q.answered and q.req.url:find('/track/batch', 1, true) then batch = true end
    end
    assert(batch, 'the event goes out while identify is unanswered')
    core:saveQueue()
    local hash = w.stored().accountHash
    for name, text in pairs(w.files) do
      if name ~= Core.IDENTITY_FILE then assert(not text:find(hash, 1, true), 'not in ' .. name) end
    end
  end },

  { 'before the opt-in yes identify is held in memory, then hashed, stored and sent on the yes', function()
    local w = world({ salt = SALT })
    local core = w.client({ consent = 'opt_in' })
    core:start()
    core:identify('u1')
    w.serve()
    eq(#w.requests, 0, 'nothing before the yes')
    eq(w.stored(), nil)
    core:setTrackingEnabled(true)
    w.serve()
    eq(w.count(), 1, 'sent after the yes')
    same_as(w.stored(), SEQ[2].expect.stored)
    core:setTrackingEnabled(false)
    eq(w.stored(), nil, 'withdrawn deletes it')
    eq(core:isIdentified(), false)
    -- A stored identity is never read before the yes.
    w.files[Core.IDENTITY_FILE] = json.encode(SEQ[2].expect.stored)
    local later = w.client({ consent = 'opt_in' })
    later:start()
    eq(later:isIdentified(), false)
  end },

  { 'opt-out deletes a stored identity and drops a held id', function()
    local w = world({ salt = SALT })
    local core = started(w)
    core:identify('u1')
    w.serve()
    assert(w.stored())
    core:setTrackingEnabled(false)
    eq(w.stored(), nil)
    eq(core:isIdentified(), false)
    local w2 = world({ salt = SALT })
    local held = w2.client()
    held:start()
    held:identify('u1')
    held:setTrackingEnabled(false)
    held:setTrackingEnabled(true)
    w2.serve()
    eq(w2.count(), 0, 'the dropped id is never sent')
  end },

  { 'a playtest run holds identify in memory and sends nothing', function()
    local w = world({ salt = SALT })
    local core = started(w, { playtest = { token = 'pt_tok', run_id = 'run1' } })
    core:identify('u1')
    w.serve()
    eq(w.count(), 0)
    eq(w.stored(), nil)
  end },

  { 'a late 200 after resetIdentity marks nothing', function()
    local w = world({ salt = SALT })
    local core = started(w)
    core:identify('u1')
    local late
    for _, q in ipairs(w.requests) do if q.req.url:find('/identify', 1, true) then late = q end end
    late.answered = true
    core:resetIdentity()
    core:track('a', {})
    core:flush()
    w.serve()
    late.cb(200, json.encode({ playerId = 'px_x' }), {})
    eq(core:isIdentified(), false)
    eq(w.stored(), nil)
    core:identify('u1')
    w.serve()
    eq(w.count(), 2, 'the same account on the new session is sent')
    eq(w.sends()[2].session, core.sessionToken)
  end },

  { 'a malformed stored identity is ignored', function()
    for _, bad in ipairs({ 'not json', '{"salt":"x","accountHash":"y"}', '[1,2]' }) do
      local w = world({ salt = SALT })
      w.files[Core.IDENTITY_FILE] = bad
      local core = started(w)
      eq(core:isIdentified(), false, bad)
      eq(w.count(), 0, bad)
    end
  end },
  { 'review F2: the same account before the salt is re-hashed under a new salt, never lost', function()
    local d = V.salts_differ
    local w = world({ salt = d.salt_a })
    local first = started(w)
    first:identify(d.accountId)
    w.serve()
    eq(w.sends()[1].accountHash, d.wire_a)
    w.salt = d.salt_b
    local core = w.client()
    core:start()
    core:identify(d.accountId)
    w.serve()
    local sends = w.sends(1)
    eq(#sends, 1, 'not lost')
    eq(sends[1].accountHash, d.wire_b, 'hashed under the new salt')
    same_as(w.stored(), { salt = d.salt_b, accountHash = d.wire_b })
  end },

  { 'review F4: before the opt-in yes a decline or resetIdentity removes an identity on disk', function()
    local saved = json.encode(SEQ[2].expect.stored)
    local w = world({ salt = SALT })
    w.files[Core.IDENTITY_FILE] = saved
    local declined = w.client({ consent = 'opt_in' })
    declined:start()
    declined:setTrackingEnabled(false)
    eq(w.files[Core.IDENTITY_FILE], nil, 'a decline deletes it')

    local w2 = world({ salt = SALT })
    local oldId = string.rep('0', 32) .. '-macos'
    w2.files[Core.IDENTITY_FILE] = saved
    w2.files[Core.DEVICE_ID_FILE] = oldId
    local core = w2.client({ consent = 'opt_in' })
    core:start()
    core:resetIdentity()
    eq(w2.files[Core.IDENTITY_FILE], nil, 'a sign-out before the yes deletes it')
    core:setTrackingEnabled(true)
    w2.serve()
    assert(core.deviceId ~= oldId and core.deviceId ~= '', 'the device is rotated')
    eq(w2.count(), 0, 'the signed-out hash is never sent')
  end },

  { 'review: a playtest run never touches the player saved identity', function()
    local saved = json.encode(SEQ[2].expect.stored)
    local w = world({ salt = SALT })
    w.files[Core.IDENTITY_FILE] = saved
    local core = started(w, { playtest = { token = 'pt_tok', run_id = 'run1' } })
    core:identify('u1')
    core:identify('u2')
    core:resetIdentity()
    eq(w.files[Core.IDENTITY_FILE], saved)
  end },
  { 'review F7: a device clock days ahead still identifies the session that just opened', function()
    local w = world({ salt = SALT })
    local core = w.client()
    core:start()
    core:identify('u1')
    for _ = 1, 20 do
      local r
      for _, q in ipairs(w.requests) do if not q.answered then r = q break end end
      if not r then break end
      r.answered = true
      local url = r.req.url
      if url:find('/settings', 1, true) then
        r.cb(200, json.encode({ trackingEnabled = true }), {})
      elseif url:find('/session', 1, true) then
        -- The absolute expiry is already past by the device clock.
        r.cb(201, json.encode({ token = 'S1', expiresIn = 86400, expiresAt = w.wall - 3 * 86400, identify = { salt = SALT } }), {})
      elseif url:find('/identify', 1, true) then
        r.cb(200, json.encode({ playerId = 'px_test' }), {})
      else
        r.cb(202, '{}', {})
      end
    end
    eq(w.count(), 1, 'identified')
  end },
}
