local Core = require('ravensight.core')
local json = require('ravensight.json')

local function eq(a, b, msg) assert(a == b, (msg or '') .. ' expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

-- A fake world: a clock the test moves, a network whose requests the test
-- answers one at a time, and storage that is a plain table.
local function harness(opts)
  opts = opts or {}
  local h = { requests = {}, files = opts.files or {}, clock = 0, wall = 1800000000, events = {}, logs = {} }
  h.core = Core.new({
    apiUrl = opts.apiUrl or 'https://api.test/',
    ingestKey = 'gt_live_k',
    gameVersion = '2.0.0',
    maxQueueSize = opts.maxQueueSize,
    log = function(level, message) table.insert(h.logs, level .. ' ' .. message) end,
    send = function(req, cb)
      -- Unavailable config must not alter the established event lifecycle.
      -- Full config transport/cache cases live in config_spec.lua.
      if req.url:find('/ingest/config?', 1, true) then cb(404, '{}', {}) return end
      table.insert(h.requests, { req = req, cb = cb })
    end,
    now = function() return h.clock end,
    time = function() return h.wall end,
    storage = {
      read = function(n) return h.files[n] end,
      write = function(n, t) h.files[n] = t end,
      remove = function(n) h.files[n] = nil end,
    },
    randomHex = function(n) return string.rep('ab', n) end,
    platform = 'macOS',
    osName = 'macos',
    playtest = opts.playtest,
    consent = opts.consent,
    distribution = opts.distribution,
    -- 0.5 is no jitter at all, so the timing tests read exact numbers.
    random = opts.random or function() return 0.5 end,
  })
  for _, name in ipairs({ 'session_ready', 'session_failed', 'tracking_disabled', 'events_flushed', 'flush_failed', 'feedback_submitted', 'feedback_failed' }) do
    h.core:on(name, function(...) table.insert(h.events, { name, ... }) end)
  end
  --- Answers the oldest unanswered request, after checking where it went.
  function h.answer(path, status, body, headers)
    local r = table.remove(h.requests, 1)
    assert(r, 'expected a request to ' .. path .. ', but none was sent')
    assert(r.req.url:sub(-#path) == path, 'expected ' .. path .. ', got ' .. r.req.url)
    r.cb(status, body and json.encode(body) or '', headers or {})
    return r.req
  end
  function h.boot(settings)
    h.core:start()
    h.answer('/api/v1/settings', 200, settings or { trackingEnabled = true })
  end
  function h.openSession()
    return h.answer('/api/v1/session', 201, { token = 'ses_1', expiresIn = 3600 })
  end
  function h.batchBody(req) return json.decode(req.body).events end
  function h.fired(name)
    for _, e in ipairs(h.events) do if e[1] == name then return e end end
  end
  return h
end

return {
  { 'a first launch saves a random device id with the OS name on it', function()
    local h = harness()
    h.core:start()
    eq(h.core.deviceId, string.rep('ab', 16) .. '-macos')
    eq(h.files[Core.DEVICE_ID_FILE], h.core.deviceId)
  end },
  { 'a saved id that is not the random shape is replaced', function()
    local h = harness({ files = { [Core.DEVICE_ID_FILE] = 'HARDWARE_ID_OS X_123' } })
    h.core:start()
    eq(h.core.deviceId, string.rep('ab', 16) .. '-macos')
  end },
  { 'boot checks the kill switch, opens a session and sends game_started', function()
    local h = harness()
    h.boot()
    local session = h.openSession()
    local body = json.decode(session.body)
    eq(body.platform, 'macOS'); eq(body.gameVersion, '2.0.0'); eq(body.deviceId, h.core.deviceId)
    eq(session.headers['X-API-Key'], 'gt_live_k')
    assert(h.fired('session_ready'))
    local batch = h.answer('/api/v1/track/batch', 202)
    eq(h.batchBody(batch)[1].event, 'game_started')
    eq(h.batchBody(batch)[1].timestamp, 1800000000)
    eq(batch.headers['X-Session-Token'], 'ses_1')
    eq(h.fired('events_flushed')[2], 1)
  end },
  { 'the server kill switch stops everything and says so', function()
    local h = harness()
    h.boot({ trackingEnabled = false })
    eq(h.core:isTrackingEnabled(), false)
    eq(h.fired('tracking_disabled')[2], 'server')
    h.core:track('anything', {})
    eq(#h.requests, 0)
  end },
  { 'an unreachable settings check assumes tracking is on', function()
    local h = harness()
    h.core:start()
    h.answer('/api/v1/settings', 0)
    eq(h.core:isTrackingEnabled(), true)
    h.openSession()
  end },
  { 'events tracked before the session are queued and sent together', function()
    local h = harness()
    h.boot()
    h.core:track('level_start', { level = 'forest_1' })
    h.core:track('level_end', { level = 'forest_1', won = true })
    h.openSession()
    local events = h.batchBody(h.answer('/api/v1/track/batch', 202))
    eq(#events, 3); eq(events[2].event, 'level_start'); eq(events[3].data.won, true)
  end },
  { 'batches hold at most 50 events and the rest follow', function()
    local h = harness({ maxQueueSize = 200 })
    h.boot()
    for i = 1, 120 do h.core:track('e' .. i, {}) end
    h.openSession()
    eq(#h.batchBody(h.answer('/api/v1/track/batch', 202)), 50)
    eq(#h.batchBody(h.answer('/api/v1/track/batch', 202)), 50)
    eq(#h.batchBody(h.answer('/api/v1/track/batch', 202)), 21)
    eq(#h.core.pending, 0)
  end },
  { 'a full queue drops the oldest event first', function()
    local h = harness({ maxQueueSize = 3 })
    h.boot()
    for i = 1, 5 do h.core:track('e' .. i, {}) end
    local names = {}
    for _, e in ipairs(h.core.pending) do names[#names + 1] = e.event end
    eq(table.concat(names, ','), 'e3,e4,e5')
  end },
  { 'a failed flush backs off from 10 seconds, doubling to a 5 minute cap', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 500)
    eq(h.core.retryAt, 10)
    h.core:track('during_backoff', {})
    eq(#h.requests, 0, 'tracking during a backoff must not send')
    h.clock = 10; h.core:update()
    h.answer('/api/v1/track/batch', 500)
    eq(h.core.retryAt, 30)
    for _ = 1, 10 do
      h.clock = h.core.retryAt; h.core:update()
      h.answer('/api/v1/track/batch', 500)
    end
    eq(h.core.retryAt - h.clock, 300)
    h.clock = h.core.retryAt; h.core:update()
    h.answer('/api/v1/track/batch', 202)
    eq(h.core.backoff, 10)
  end },
  { 'a 429 waits exactly as long as Retry-After says', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 429, { error = 'rate_limited' }, { ['retry-after'] = '42' })
    eq(h.core.retryAt, 42)
    eq(h.fired('flush_failed')[2], 'rate_limited')
  end },
  { 'a rejected batch is halved until the one bad event is dropped', function()
    local h = harness()
    h.boot()
    for i = 1, 3 do h.core:track('e' .. i, {}) end
    h.openSession()
    h.answer('/api/v1/track/batch', 400, { error = 'event_too_large' })
    eq(#h.batchBody(h.answer('/api/v1/track/batch', 400, { error = 'event_too_large' })), 2)
    eq(#h.batchBody(h.answer('/api/v1/track/batch', 400, { error = 'event_too_large' })), 1)
    -- game_started was the bad one; the other three survive.
    eq(#h.core.pending, 3)
    eq(h.core.pending[1].event, 'e1')
  end },
  { 'a 401 opens a new session and keeps the queue', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 401)
    eq(#h.core.pending, 1)
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
    eq(#h.core.pending, 0)
  end },
  { 'the kill switch turning off mid-run ends tracking for the run', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 403, { error = 'tracking_disabled' })
    eq(h.core:isTrackingEnabled(), false)
    eq(#h.core.pending, 0)
    eq(h.fired('tracking_disabled')[2], 'server')
  end },
  { 'opting out drops the queue, saves the choice and sends nothing next launch', function()
    local h = harness()
    h.boot()
    h.core:track('queued', {})
    h.core:setTrackingEnabled(false)
    eq(#h.core.pending, 0)
    eq(h.files[Core.OPTOUT_FILE], '1')
    eq(h.fired('tracking_disabled')[2], 'player')
    h.requests = {}
    local next = harness({ files = h.files })
    next.core:start()
    eq(#next.requests, 0, 'an opted-out player sends not even the settings check')
    eq(next.core:isTrackingEnabled(), false)
  end },
  { 'opting back in re-reads the kill switch and starts again', function()
    local h = harness({ files = { [Core.OPTOUT_FILE] = '1' } })
    h.core:start()
    h.core:setTrackingEnabled(true)
    eq(h.files[Core.OPTOUT_FILE], nil)
    h.answer('/api/v1/settings', 200, { trackingEnabled = true })
    h.openSession()
    eq(h.batchBody(h.answer('/api/v1/track/batch', 202))[1].event, 'game_started')
  end },
  { 'enabling tracking for a player who never opted out changes nothing', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
    h.core:setTrackingEnabled(true)
    eq(#h.requests, 0)
  end },
  { 'resetting the device id makes a new one and ends the session', function()
    local h = harness()
    h.boot()
    h.openSession()
    local rand = 0
    h.core.randomHex = function(n) rand = rand + 1 return string.rep('c' .. rand, n) end
    h.core:resetDeviceId()
    eq(h.core.deviceId, string.rep('c1', 16) .. '-macos')
    eq(h.files[Core.DEVICE_ID_FILE], h.core.deviceId)
    eq(h.core.sessionToken, '')
    -- The batch already in flight belongs to the old queue and is ignored.
    h.answer('/api/v1/track/batch', 202)
    eq(h.fired('events_flushed'), nil)
  end },
  { 'a response for an abandoned session attempt is ignored', function()
    local h = harness()
    h.boot()
    h.core:dropSession()
    h.openSession()
    eq(h.core.sessionToken, '')
  end },
  { 'quitting sends game_exited and is released when the flush is answered', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
    eq(h.core:beginQuit(), true)
    eq(h.core.quitReady, false)
    eq(h.batchBody(h.answer('/api/v1/track/batch', 202))[1].event, 'game_exited')
    eq(h.core.quitReady, true)
    eq(h.files[Core.QUEUE_FILE], nil)
  end },
  { 'quitting gives up after 1.5 seconds and saves what was not sent', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
    h.core:track('last_words', {})
    h.core:beginQuit()
    h.clock = 1.6; h.core:update()
    eq(h.core.quitReady, true)
    local saved = json.decode(h.files[Core.QUEUE_FILE])
    eq(saved[#saved].event, 'game_exited')
  end },
  { 'quitting offline quits at once and the next launch sends the saved events', function()
    local h = harness()
    h.core:start()
    h.answer('/api/v1/settings', 0)
    h.core:track('offline_play', {})
    h.answer('/api/v1/session', 0)
    eq(h.core:beginQuit(), false)
    assert(h.files[Core.QUEUE_FILE])
    local next = harness({ files = h.files })
    next.boot()
    eq(next.files[Core.QUEUE_FILE], nil)
    next.openSession()
    local names = {}
    for _, e in ipairs(next.batchBody(next.answer('/api/v1/track/batch', 202))) do names[#names + 1] = e.event end
    eq(table.concat(names, ','), 'game_started,offline_play,game_exited,game_started')
  end },
  { 'feedback needs a session, and says why when it fails', function()
    local h = harness()
    h.boot()
    h.core:submitFeedback('the boss is too hard')
    eq(h.fired('feedback_failed')[2], 'no_session')
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
    eq(h.core:submitFeedback('the boss is too hard', 'suggestion', 2), true)
    local req = h.answer('/api/v1/feedback', 201)
    local body = json.decode(req.body)
    eq(body.category, 'suggestion'); eq(body.rating, 2)
    assert(h.fired('feedback_submitted'))
  end },
  { 'a playtest run tags every event, never saves its id and ignores an opt-out', function()
    local h = harness({ files = { [Core.OPTOUT_FILE] = '1' }, playtest = { token = 'pt_tok', run_id = 'run9', persona = 'speedrunner' } })
    h.boot()
    eq(h.core.deviceId, 'pt-run9')
    eq(h.files[Core.DEVICE_ID_FILE], nil)
    local session = h.openSession()
    eq(session.headers['X-Ravensight-Playtest'], 'pt_tok')
    eq(json.decode(session.body).platform, 'ravensight-playtest')
    local caller = { x = 1 }
    h.core:track('jump', caller)
    local events = h.batchBody(h.answer('/api/v1/track/batch', 202))
    eq(events[1].data.synthetic, true); eq(events[1].data.pt_run, 'run9'); eq(events[1].data.persona, 'speedrunner')
    eq(caller.synthetic, nil, "the caller's table is never changed")
  end },
  { 'a rejected playtest token is never retried', function()
    local h = harness({ playtest = { token = 'bad', run_id = 'r' } })
    h.boot()
    h.answer('/api/v1/session', 403, { error = 'invalid_playtest_token' })
    h.core:track('more', {})
    eq(#h.requests, 0)
  end },
  { 'track refuses a non-table payload with a clear message', function()
    local h = harness()
    h.boot()
    local ok, err = pcall(h.core.track, h.core, 'e', 'not a table')
    assert(not ok and tostring(err):find('data must be a table'))
  end },
  { 'a listener that errors does not break the SDK', function()
    local h = harness()
    h.core:on('session_ready', function() error('game bug') end)
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
  end },
  { 'six quick events go out as one request, and a later one after the interval', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
    for i = 1, 6 do h.core:track('e' .. i, { i = i }) end
    eq(#h.requests, 0, 'track must not send at once')
    h.clock = 1.9; h.core:update()
    eq(#h.requests, 0, 'nothing is sent before the interval')
    h.clock = 2.0; h.core:update()
    local events = h.batchBody(h.answer('/api/v1/track/batch', 202))
    eq(#events, 6)
    eq(h.fired('events_flushed') and h.events[#h.events][2], 6)
    local logged = false
    for _, line in ipairs(h.logs) do if line == 'info events_flushed 6' then logged = true end end
    assert(logged, 'expected the events_flushed 6 debug line')
    h.core:track('e7', {})
    h.clock = 3.9; h.core:update()
    eq(#h.requests, 0, 'the seventh waits its own interval')
    h.clock = 4.1; h.core:update()
    eq(h.batchBody(h.answer('/api/v1/track/batch', 202))[1].event, 'e7')
  end },
  { 'flushInterval is an option', function()
    local h = harness()
    h.core.flushInterval = 0.5
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
    h.core:track('quick', {})
    h.clock = 0.5; h.core:update()
    h.answer('/api/v1/track/batch', 202)
  end },
  { 'a full request worth of events is sent without waiting', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
    for i = 1, 49 do h.core:track('e' .. i, {}) end
    eq(#h.requests, 0)
    h.core:track('e50', {})
    eq(#h.batchBody(h.answer('/api/v1/track/batch', 202)), 50)
  end },
  { 'flush() sends at once', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
    h.core:track('now', {})
    h.core:flush()
    eq(h.batchBody(h.answer('/api/v1/track/batch', 202))[1].event, 'now')
  end },
  { 'apiUrl works with or without a trailing slash and /api/v1', function()
    for _, url in ipairs({ 'https://api.ravensight.io', 'https://api.ravensight.io/', 'https://api.ravensight.io/api/v1', 'https://api.ravensight.io/api/v1/' }) do
      local h = harness({ apiUrl = url })
      h.core:start()
      eq(h.requests[1].req.url, 'https://api.ravensight.io/api/v1/settings', url)
      h.answer('/api/v1/settings', 200, { trackingEnabled = true })
      eq(h.requests[1].req.url, 'https://api.ravensight.io/api/v1/session', url)
    end
  end },
  { 'maxQueueSize defaults to 500', function()
    local h = harness()
    eq(h.core.maxQueueSize, 500)
  end },
  { 'an unknown feedback category is refused here and nothing is sent', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
    local ok, reason = h.core:submitFeedback('nice', 'example', 5)
    eq(ok, false); eq(reason, 'invalid_category')
    eq(#h.requests, 0)
    eq(h.fired('feedback_failed')[2], 'invalid_category')
    eq(h.logs[#h.logs], 'warn feedback_rejected invalid_category example')
  end },
  { 'every documented feedback category is accepted, and none at all', function()
    for _, category in ipairs({ 'bug', 'suggestion', 'complaint', 'praise', 'playtest', 'other', nil }) do
      local h = harness()
      h.boot()
      h.openSession()
      h.answer('/api/v1/track/batch', 202)
      eq(h.core:submitFeedback('hi', category), true)
      h.answer('/api/v1/feedback', 201)
    end
  end },
  { 'an event tracked while a request is in flight is sent right after the 202', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.core:track('during_flight', {})
    eq(#h.requests, 1, 'only the game_started batch is out')
    h.answer('/api/v1/track/batch', 202)
    eq(h.batchBody(h.answer('/api/v1/track/batch', 202))[1].event, 'during_flight')
  end },
  { 'a feedback rating outside 1 to 5 or not whole is refused here', function()
    local h = harness()
    h.boot()
    h.openSession()
    h.answer('/api/v1/track/batch', 202)
    for _, bad in ipairs({ 0, 6, 4.5, 'good' }) do
      local ok, reason = h.core:submitFeedback('hi', 'praise', bad)
      eq(ok, false, tostring(bad)); eq(reason, 'invalid_rating', tostring(bad))
    end
    eq(#h.requests, 0)
    eq(h.fired('feedback_failed')[2], 'invalid_rating')
    eq(h.logs[#h.logs], 'warn feedback_rejected invalid_rating good')
    eq(h.core:submitFeedback('hi', 'praise', 5), true)
    eq(json.decode(h.answer('/api/v1/feedback', 201).body).rating, 5)
  end },

  -- ------------------------------------------------------- 0.3.0: opt-in

  { 'opt_in: nothing at all before the player says yes', function()
    local h = harness({ consent = 'opt_in', files = { [Core.QUEUE_FILE] = '[{"event":"old","data":{},"timestamp":1}]' } })
    h.core:start()
    eq(#h.requests, 0, 'no settings call')
    eq(h.core.deviceId, '', 'no device id')
    eq(h.files[Core.DEVICE_ID_FILE], nil, 'no device id file')
    eq(#h.core.pending, 0, 'the saved queue is not loaded')
    eq(h.core:isTrackingEnabled(), false)
    eq(h.fired('tracking_disabled')[2], 'player')
    h.core:track('ignored', {})
    eq(#h.core.pending, 0)
    eq(h.core:beginQuit(), false)
    eq(h.files[Core.DEVICE_ID_FILE], nil, 'quitting writes no id either')
  end },
  { 'opt_in: setTrackingEnabled(true) saves ravensight_optin, makes the id and starts', function()
    local h = harness({ consent = 'opt_in' })
    h.core:start()
    h.core:setTrackingEnabled(true)
    eq(h.files[Core.OPTIN_FILE], '1')
    eq(h.files[Core.OPTOUT_FILE], nil)
    eq(h.core.deviceId, string.rep('ab', 16) .. '-macos')
    h.answer('/api/v1/settings', 200, { trackingEnabled = true })
    h.openSession()
    eq(h.batchBody(h.answer('/api/v1/track/batch', 202))[1].event, 'game_started')
    -- The next launch remembers the yes.
    local next = harness({ consent = 'opt_in', files = h.files })
    next.boot()
    eq(next.core.deviceId, h.core.deviceId)
  end },
  { 'opt_in: saying no again removes ravensight_optin and stops', function()
    local h = harness({ consent = 'opt_in', files = { [Core.OPTIN_FILE] = '1' } })
    h.boot()
    h.core:setTrackingEnabled(false)
    eq(h.files[Core.OPTIN_FILE], nil)
    eq(h.files[Core.OPTOUT_FILE], nil, 'opt_in never writes the opt-out file')
    eq(h.core:isTrackingEnabled(), false)
  end },
  { 'opt_in: resetDeviceId before a yes makes no id', function()
    local h = harness({ consent = 'opt_in', files = { [Core.DEVICE_ID_FILE] = string.rep('cd', 16) .. '-macos' } })
    h.core:start()
    h.core:resetDeviceId()
    eq(h.files[Core.DEVICE_ID_FILE], nil)
    eq(h.core.deviceId, '')
  end },
  { 'opt_out stays the default and reads only ravensight_optout', function()
    local h = harness({ files = { [Core.OPTIN_FILE] = '1' } })
    eq(h.core.consent, 'opt_out')
    h.boot()
    eq(h.core:isTrackingEnabled(), true)
    local unknown = harness({ consent = 'something' })
    eq(unknown.core.consent, 'opt_out')
  end },

  -- ------------------------------------------------- 0.3.0: distribution

  { 'distribution is sent on the session body only when set', function()
    local h = harness({ distribution = 'web-itch' })
    h.boot()
    eq(json.decode(h.openSession().body).distribution, 'web-itch')
    local plain = harness()
    plain.boot()
    eq(json.decode(plain.openSession().body).distribution, nil)
  end },

  -- ---------------------------------------------- 0.3.0: a refused key

  { 'a 401 on settings ends the run: no session, no retry, nothing saved', function()
    local h = harness({ files = { [Core.QUEUE_FILE] = '[{"event":"old","data":{},"timestamp":1}]' } })
    h.core:start()
    eq(#h.core.pending, 1, 'the saved queue was loaded')
    h.answer('/api/v1/settings', 401, { error = 'invalid_api_key' })
    eq(#h.requests, 0)
    eq(h.core:isTrackingEnabled(), false)
    eq(#h.core.pending, 0, 'the queue is cleared')
    eq(h.fired('tracking_disabled')[2], 'key')
    h.core:track('more', {})
    for t = 1, 400, 10 do h.clock = t; h.core:update() end
    eq(#h.requests, 0, 'never retried')
    eq(h.core:beginQuit(), false)
    eq(h.files[Core.QUEUE_FILE], nil, 'nothing saved on quit')
    local logged = 0
    for _, line in ipairs(h.logs) do if line:find('ingest key was refused', 1, true) then logged = logged + 1 end end
    eq(logged, 1, 'logged once')
  end },
  { 'a 403 on settings that is not the kill switch also ends the run', function()
    local h = harness()
    h.core:start()
    h.answer('/api/v1/settings', 403, { error = 'key_revoked' })
    eq(h.fired('tracking_disabled')[2], 'key')
    eq(#h.requests, 0)
  end },
  { 'a 403 tracking_disabled on settings is the kill switch, not a key refusal', function()
    local h = harness()
    h.core:start()
    h.answer('/api/v1/settings', 403, { error = 'tracking_disabled' })
    eq(h.fired('tracking_disabled')[2], 'server')
  end },
  { 'a 401 or 403 on the session ends the run and is never retried', function()
    for _, status in ipairs({ 401, 403 }) do
      local h = harness()
      h.boot()
      h.answer('/api/v1/session', status, { error = 'invalid_api_key' })
      eq(h.fired('session_failed')[2], 'invalid_api_key')
      eq(h.fired('tracking_disabled')[2], 'key', tostring(status))
      eq(h.core.retryAt, nil)
      h.core:track('x', {})
      h.clock = 1000; h.core:update()
      eq(#h.requests, 0, tostring(status))
      -- The player's choice is still saved, but nothing restarts.
      h.core:setTrackingEnabled(false)
      h.core:setTrackingEnabled(true)
      eq(h.files[Core.OPTOUT_FILE], nil)
      eq(#h.requests, 0)
    end
  end },
  { 'playtest refusals and the kill switch keep their 0.2.0 meaning on the session', function()
    local h = harness({ playtest = { token = 'bad', run_id = 'r' } })
    h.boot()
    h.answer('/api/v1/session', 403, { error = 'playtest_job_closed' })
    eq(h.fired('tracking_disabled'), nil)
    local k = harness()
    k.boot()
    k.answer('/api/v1/session', 403, { error = 'tracking_disabled' })
    eq(k.fired('tracking_disabled')[2], 'server')
  end },
  { 'a refused key while quitting releases the quit at once', function()
    local h = harness()
    h.boot()
    h.core:track('last', {})
    eq(h.core:beginQuit(), true)
    h.answer('/api/v1/session', 401)
    eq(h.core.quitReady, true)
    eq(h.files[Core.QUEUE_FILE], nil)
  end },

  -- --------------------------------------------------- 0.3.0: jitter

  { 'backoff carries plus or minus 20 percent jitter from deps.random', function()
    local low = harness({ random = function() return 0 end })
    low.boot(); low.openSession()
    low.answer('/api/v1/track/batch', 500)
    eq(low.core.retryAt, 8)
    local high = harness({ random = function() return 1 end })
    high.boot(); high.openSession()
    high.answer('/api/v1/track/batch', 500)
    assert(math.abs(high.core.retryAt - 12) < 1e-9, 'expected 12, got ' .. high.core.retryAt)
  end },
  { 'jitter never takes a wait past 5 minutes or under half a second', function()
    local h = harness({ random = function() return 1 end })
    h.boot(); h.openSession()
    h.core.backoff = 300
    h.answer('/api/v1/track/batch', 500)
    eq(h.core.retryAt, 300)
    local tiny = harness({ random = function() return 0 end })
    tiny.boot(); tiny.openSession()
    tiny.core.backoff = 0.1
    tiny.answer('/api/v1/track/batch', 500)
    eq(tiny.core.retryAt, 0.5)
  end },
  { 'Retry-After is obeyed exactly, with no jitter', function()
    local h = harness({ random = function() return 1 end })
    h.boot(); h.openSession()
    h.answer('/api/v1/track/batch', 429, { error = 'quota_exceeded' }, { ['retry-after'] = '42' })
    eq(h.core.retryAt, 42)
  end },

  -- ------------------------------------------------ 0.3.0: rs_event_id

  { 'every event carries a distinct rs_event_id and the caller table is untouched', function()
    local h = harness()
    h.boot()
    local caller = { a = 1 }
    h.core:track('one', caller)
    h.core:track('two', caller)
    eq(caller.rs_event_id, nil)
    h.openSession()
    local events = h.batchBody(h.answer('/api/v1/track/batch', 202))
    local prefix = string.rep('ab', 8) .. '-' .. string.format('%x', 1800000000) .. '-abababab-'
    eq(events[1].data.rs_event_id, prefix .. '1', 'game_started')
    eq(events[2].data.rs_event_id, prefix .. '2')
    eq(events[3].data.rs_event_id, prefix .. '3')
  end },
  { 'rs_event_id survives a saved queue and a reload', function()
    local h = harness()
    h.core:start()
    h.answer('/api/v1/settings', 0)
    h.core:track('offline', {})
    h.answer('/api/v1/session', 0)
    h.core:beginQuit()
    local ids = {}
    for _, e in ipairs(json.decode(h.files[Core.QUEUE_FILE])) do ids[e.event] = e.data.rs_event_id end
    assert(ids.offline, 'saved with its id')
    local next = harness({ files = h.files })
    next.core.randomHex = function(n) return string.rep('cd', n) end   -- another launch, another nonce
    next.boot()
    next.openSession()
    local sent = {}
    for _, e in ipairs(next.batchBody(next.answer('/api/v1/track/batch', 202))) do sent[#sent + 1] = e end
    eq(sent[2].event, 'offline')
    eq(sent[2].data.rs_event_id, ids.offline)
    assert(sent[4].data.rs_event_id ~= ids.game_started, 'a new launch makes new ids')
  end },
  { 'a playtest event id starts with the throwaway id', function()
    local h = harness({ playtest = { token = 't', run_id = 'run9' } })
    h.boot()
    eq(h.core.pending[1].data.rs_event_id:sub(1, 8), 'pt-run9-')
  end },

  -- ------------------------------------------ 0.3.0: oversized events

  { 'an event over 8,192 bytes is dropped with one warning and flush_failed', function()
    local h = harness()
    h.boot()
    local tracked = 0
    h.core:on('event_tracked', function() tracked = tracked + 1 end)
    h.core:track('huge', { blob = string.rep('x', 9000) })
    h.core:track('huge', { blob = string.rep('x', 9000) })
    eq(#h.core.pending, 1, 'only game_started is queued')
    eq(tracked, 0, 'no event_tracked for a dropped event')
    local failures, warnings = 0, 0
    for _, e in ipairs(h.events) do if e[1] == 'flush_failed' and e[2] == 'event_too_large' then failures = failures + 1 end end
    for _, line in ipairs(h.logs) do if line:find('dropped event "huge"', 1, true) then warnings = warnings + 1 end end
    eq(failures, 2); eq(warnings, 1)
    -- Just under the limit is kept.
    -- The data alone is measured, as the server does.
    local data = { blob = '' }
    data.rs_event_id = Core.eventId(h.core.deviceId, h.core.startTime, 'abababab', 4)
    local room = Core.MAX_EVENT_BYTES - Core.eventBytes(data)
    h.core:track('a_long_event_name_that_the_server_does_not_count', { blob = string.rep('y', room) })
    eq(#h.core.pending, 2)
    eq(Core.eventBytes(h.core.pending[2].data), Core.MAX_EVENT_BYTES)
  end },

  -- ------------------------------------------ 0.3.0: what leaves, exactly

  { 'every outgoing request has exactly the documented keys and headers', function()
    local h = harness({ distribution = 'native-release' })
    local function keys(t)
      local out = {}
      for k in pairs(t or {}) do out[#out + 1] = k end
      table.sort(out)
      return table.concat(out, ',')
    end
    h.core:start()
    local settings = h.answer('/api/v1/settings', 200, { trackingEnabled = true })
    eq(keys(settings), 'headers,method,url')
    eq(settings.method, 'GET')
    eq(settings.url, 'https://api.test/api/v1/settings')
    eq(keys(settings.headers), 'X-API-Key')

    h.core:track('level_start', { level = 'forest_1' })
    local session = h.openSession()
    eq(keys(session), 'body,headers,method,url')
    eq(session.url, 'https://api.test/api/v1/session')
    eq(keys(session.headers), 'Content-Type,X-API-Key')
    eq(keys(json.decode(session.body)), 'deviceId,distribution,gameVersion,platform,sdk')

    local batch = h.answer('/api/v1/track/batch', 202)
    eq(batch.url, 'https://api.test/api/v1/track/batch')
    eq(keys(batch.headers), 'Content-Type,X-Session-Token')
    local body = json.decode(batch.body)
    eq(keys(body), 'events')
    for _, e in ipairs(body.events) do eq(keys(e), 'data,event,timestamp') end
    eq(keys(body.events[1].data), 'rs_event_id')
    eq(keys(body.events[2].data), 'level,rs_event_id')

    h.core:submitFeedback('hi', 'bug', 3)
    local feedback = h.answer('/api/v1/feedback', 201)
    eq(feedback.url, 'https://api.test/api/v1/feedback')
    eq(keys(feedback.headers), 'Content-Type,X-Session-Token')
    eq(keys(json.decode(feedback.body)), 'category,message,rating')
  end },
  { 'opt_in: events tracked right after the yes are queued, before the settings answer', function()
    local h = harness({ consent = 'opt_in' })
    h.core:start()
    h.core:setTrackingEnabled(true)
    eq(h.core:isTrackingEnabled(), true)
    h.core:track('tutorial_started', {})
    eq(#h.core.pending, 1, 'queued')
    eq(#h.requests, 1, 'only the settings check is out: no session before its answer')
    h.answer('/api/v1/settings', 200, { trackingEnabled = true })
    h.openSession()
    local names = {}
    for _, e in ipairs(h.batchBody(h.answer('/api/v1/track/batch', 202))) do names[#names + 1] = e.event end
    eq(table.concat(names, ','), 'tutorial_started,game_started')
  end },
  { 'opt_in: the server saying no after the yes clears what was queued', function()
    local h = harness({ consent = 'opt_in' })
    h.core:start()
    h.core:setTrackingEnabled(true)
    h.core:track('tutorial_started', {})
    h.answer('/api/v1/settings', 200, { trackingEnabled = false })
    eq(#h.core.pending, 0)
    eq(h.core:isTrackingEnabled(), false)
    eq(#h.requests, 0)
  end },
  { 'opt_out start: a track during the settings check waits for its answer', function()
    -- 200 with tracking on: the answer opens the session, and both events go.
    local on = harness()
    on.core:start()
    on.core:track('menu_opened', {})
    eq(#on.requests, 1, 'only the settings check is out')
    on.answer('/api/v1/settings', 200, { trackingEnabled = true })
    on.openSession()
    local names = {}
    for _, e in ipairs(on.batchBody(on.answer('/api/v1/track/batch', 202))) do names[#names + 1] = e.event end
    eq(table.concat(names, ','), 'menu_opened,game_started')

    -- A timeout (status 0) or a 5xx fails open: the session still opens.
    for _, status in ipairs({ 0, 503 }) do
      local h = harness()
      h.core:start()
      h.core:track('menu_opened', {})
      eq(#h.requests, 1, tostring(status))
      h.answer('/api/v1/settings', status)
      eq(h.core:isTrackingEnabled(), true, tostring(status))
      h.openSession()
      eq(#h.batchBody(h.answer('/api/v1/track/batch', 202)), 2, tostring(status))
    end

    -- 200 with tracking off: the queued event is dropped and nothing opens.
    local off = harness()
    off.core:start()
    off.core:track('menu_opened', {})
    off.answer('/api/v1/settings', 200, { trackingEnabled = false })
    eq(#off.core.pending, 0)
    eq(#off.requests, 0)
    eq(off.fired('tracking_disabled')[2], 'server')
  end },
}
