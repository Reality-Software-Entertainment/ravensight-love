-- Campaign links in the core: setCampaignLink(id), campaignLink on the next
-- POST /api/v1/session of the player's own session, cleared only by a 201
-- with a token. The core's fake world: a clock, a network the test answers
-- and storage that is a plain table. Sessions answer S1, S2, ... in order.

local Core = require('ravensight.core')
local json = require('ravensight.json')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local LINK = '64b0000000000000000000a1'
local LINK2 = '64b0000000000000000000b2'

local function world()
  local w = { files = {}, requests = {}, sessions = 0, wall = 1800000000, clock = 0 }
  function w.client(extra)
    extra = extra or {}
    return Core.new({
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
      random = function() return 1 end,
    })
  end
  --- The oldest unanswered request, or nil.
  function w.open()
    for _, q in ipairs(w.requests) do if not q.answered then return q end end
  end
  --- Answers the oldest unanswered request.
  function w.answer(status, body, headers)
    local q = assert(w.open(), 'a request to answer')
    q.answered = true
    q.cb(status, type(body) == 'table' and json.encode(body) or (body or ''), headers or {})
    return q
  end
  --- Answers every open request: settings on, sessions S1, S2, ..., batches accepted.
  function w.serve()
    for _ = 1, 100 do
      local q = w.open()
      if not q then return end
      local url = q.req.url
      if url:find('/api/v1/settings', 1, true) then
        w.answer(200, { trackingEnabled = true })
      elseif url:find('/api/v1/session', 1, true) then
        w.sessions = w.sessions + 1
        w.answer(201, { token = 'S' .. w.sessions, expiresIn = 86400 })
      elseif url:find('/api/v1/track/batch', 1, true) then
        w.answer(202, { accepted = 1 })
      else
        w.answer(404, {})
      end
    end
  end
  --- The campaignLink of every session request so far, '-' for none.
  function w.links()
    local out = {}
    for _, q in ipairs(w.requests) do
      if q.req.url:find('/api/v1/session', 1, true) then
        out[#out + 1] = json.decode(q.req.body).campaignLink or '-'
      end
    end
    return table.concat(out, ',')
  end
  --- The session ends; the next event opens a new one.
  function w.nextSession(core)
    w.wall = w.wall + 90000
    core:track('tick', {})
    core:flush()
    w.serve()
  end
  --- True when no saved file holds `text`.
  function w.nothingSavedHolds(text)
    for _, content in pairs(w.files) do
      if tostring(content):lower():find(text:lower(), 1, true) then return false end
    end
    return true
  end
  return w
end

return {
  { 'a link id in upper case is sent lowercased on the first session, once', function()
    local w = world()
    local core = w.client()
    eq(core:setCampaignLink(LINK:upper()), true, 'accepted')
    core:start()
    w.serve()
    eq(w.links(), LINK, 'campaignLink on the first POST /session')
    eq(core.sessionToken, 'S1')
    w.nextSession(core)
    eq(w.links(), LINK .. ',-', 'the next session of the same client carries none')
    assert(w.nothingSavedHolds(LINK), 'the link is never saved')
    eq(core:setCampaignLink(LINK2), true, 'a later call is accepted')
    w.nextSession(core)
    w.nextSession(core)
    eq(w.links(), LINK .. ',-,' .. LINK2 .. ',-', 'a later call goes with the next session only')
    -- A second client in the same process carries none unless set again.
    local w2 = world()
    w2.client():start()
    w2.serve()
    eq(w2.links(), '-', 'a new client starts with no link')
  end },

  { 'anything but a link id is refused, sends nothing and keeps a link already set', function()
    local bad = { '', 'abc', LINK:sub(1, 23), LINK .. '0', string.rep('g', 24), ' ' .. LINK, LINK .. ' ',
      LINK .. '\n', '\n' .. LINK, LINK:sub(1, 22) .. '-1', LINK:sub(1, 23) .. '\0', 12345, 6.4e23, true, {}, function() end }
    for i, value in ipairs(bad) do
      local w = world()
      local core = w.client()
      eq(core:setCampaignLink(value), false, 'refused #' .. i)
      core:start()
      w.serve()
      eq(w.links(), '-', 'nothing sent for #' .. i)
    end
    local w = world()
    local core = w.client()
    eq(core:setCampaignLink(nil), false, 'nil is refused')
    eq(core:setCampaignLink(LINK), true)
    eq(core:setCampaignLink('zz'), false)
    eq(core:setCampaignLink(nil), false)
    core:start()
    w.serve()
    eq(w.links(), LINK, 'an invalid call keeps the earlier link')
  end },

  { 'Core.campaignLinkId accepts 24 hex characters in any case and lowercases them', function()
    eq(Core.campaignLinkId(LINK), LINK)
    eq(Core.campaignLinkId('ABCDEF0123456789ABCDEF01'), 'abcdef0123456789abcdef01')
    eq(Core.campaignLinkId('abcdeg0123456789abcdef01'), nil)
    eq(Core.campaignLinkId(nil), nil)
  end },

  { 'a failed, offline, rate-limited or token-less session keeps the link for the next attempt', function()
    local w = world()
    local core = w.client()
    core:setCampaignLink(LINK)
    core:start()
    w.answer(200, { trackingEnabled = true })
    w.answer(500, { error = 'internal_error' })
    w.clock = w.clock + 10; core:update()
    w.answer(0, '')
    w.clock = w.clock + 20; core:update()
    w.answer(429, { error = 'rate_limited' }, { ['retry-after'] = '5' })
    w.clock = w.clock + 5; core:update()
    w.answer(201, { expiresIn = 86400 })
    local four = table.concat({ LINK, LINK, LINK, LINK }, ',')
    eq(w.links(), four, 'every attempt carried it')
    core:flush()
    w.serve()
    eq(w.links(), four .. ',' .. LINK, 'the next attempt carries it')
    eq(core.sessionToken, 'S1', 'and opens the session')
    w.nextSession(core)
    eq(w.links(), four .. ',' .. LINK .. ',-', 'cleared once a session answered 201 with a token')
  end },

  { 'a link set while a session is opening goes with the next one', function()
    local w = world()
    local core = w.client()
    core:setCampaignLink(LINK)
    core:start()
    w.answer(200, { trackingEnabled = true })
    eq(w.links(), LINK)
    core:setCampaignLink(LINK2)
    w.serve()
    w.nextSession(core)
    w.nextSession(core)
    eq(w.links(), LINK .. ',' .. LINK2 .. ',-')
  end },

  { 'a 201 the core ignores (a reset while in flight) still clears the link it carried', function()
    local w = world()
    local core = w.client()
    core:setCampaignLink(LINK)
    core:start()
    w.answer(200, { trackingEnabled = true })
    core:resetDeviceId()
    w.answer(201, { token = 'old', expiresIn = 86400 })
    eq(core.sessionToken, '', 'the stale answer is ignored')
    core:track('x', {})
    w.serve()
    eq(w.links(), LINK .. ',-', 'the next session carries none')
  end },

  { 'opt_in: nothing before the yes, the link goes with the first session after it; opted out sends nothing', function()
    local w = world()
    local core = w.client({ consent = 'opt_in' })
    eq(core:setCampaignLink(LINK), true)
    core:start()
    core:track('before', {})
    core:flush()
    w.clock = w.clock + 3600; core:update()
    eq(#w.requests, 0, 'no request before the yes')
    core:setTrackingEnabled(true)
    w.serve()
    eq(w.links(), LINK, 'with the first session after the yes')

    local out = world()
    out.files[Core.OPTOUT_FILE] = '1'
    local opted = out.client()
    opted:setCampaignLink(LINK)
    opted:start()
    opted:track('x', {})
    opted:flush()
    out.clock = out.clock + 3600; opted:update()
    eq(#out.requests, 0, 'an opted out player sends nothing')
  end },

  { 'a playtest session never carries the link and does not clear it', function()
    local w = world()
    local core = w.client({ playtest = { token = 'pt_tok', run_id = 'run42' } })
    eq(core:setCampaignLink(LINK), true)
    core:start()
    w.serve()
    eq(w.links(), '-')
    eq(core.campaignLink, LINK, 'still waiting')
  end },
}
