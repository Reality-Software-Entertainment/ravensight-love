local Core = require('ravensight.core')
local Web = require('ravensight.web')
local json = require('ravensight.json')
local Config = require('ravensight.config')
local function eq(a,b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function doc() return { values = { speed = 3, hints = false, rules = { bonus = 2 } }, experiments = {{ key = 'difficulty', variant = 'easy' }}, etag = '"' .. string.rep('a',64) .. '"' } end
local function make(files)
  local h = { files = files or {}, requests = {}, ready = {} }
  h.core = Core.new({ apiUrl = 'https://api.test', ingestKey = 'public', platform = 'web', gameVersion = '1', randomHex = function(n) return string.rep('a', n*2) end,
    storage = { read = function(k) return h.files[k] end, write = function(k,v) h.files[k] = v end, remove = function(k) h.files[k] = nil end },
    send = function(req, cb) table.insert(h.requests, {req=req,cb=cb}) end })
  h.core.deviceId = 'player'
  h.core:on('config_ready', function(source) table.insert(h.ready, source) end)
  function h.answer(status, body)
    local r = table.remove(h.requests,1); assert(r)
    r.cb(status, body and json.encode(body) or '', {})
    return r.req
  end
  return h
end
return {
  {'reserved config keys remain forbidden while experiment words are values', function()
    for _, word in ipairs({'constructor','prototype'}) do
      local candidate = doc(); candidate.values = {[word]=1}; eq(Config.valid(candidate),false)
      candidate.values = {nested={[word]=1}}; eq(Config.valid(candidate),false)
      candidate.values = {}; candidate.experiments = {{key=word,variant=word}}; eq(Config.valid(candidate),true)
    end
  end},
  {'config fetch, ETag, strict getters and labels', function()
    local h = make(); assert(h.core:fetchConfig()); eq(h.core:fetchConfig(), false)
    local req = h.answer(200, doc()); eq(req.method,'GET'); eq(req.headers['X-API-Key'],'public')
    assert(req.url:find('/api/v1/ingest/config?deviceId=player&platform=web&gameVersion=1',1,true))
    eq(h.ready[1],'network'); eq(h.core:getConfig('speed',0),3); eq(h.core:getConfig('hints',true),false)
    eq(h.core:getConfig('speed','fallback'),'fallback'); eq(h.core:getConfig('missing',8),8)
    h.core:getConfig('rules',{}).bonus = 99; eq(h.core:getConfig('rules',{}).bonus,2)
    local event = h.core:enqueue('x', {rs_exp_difficulty='forged'}); eq(event.rs_exp_difficulty,'easy')
    h.core:fetchConfig(); req = h.answer(304); eq(req.headers['If-None-Match'],doc().etag); eq(h.ready[2],'cache')
    h.core:fetchConfig(); h.answer(0); eq(h.core:getConfig('speed',0),3)
    local empty = doc(); empty.values={}; empty.experiments={}; h.core:fetchConfig(); h.answer(200,empty)
    eq(h.core:getConfig('speed',0),0); eq(h.core:enqueue('x',{}).rs_exp_difficulty,nil)
  end},
  {'persistent scope and stale identity responses',function()
    local h = make(); h.core:fetchConfig(); h.answer(200,doc())
    local restored = make(h.files); eq(restored.core:getConfig('speed',0),3)
    for key, value in pairs({gameVersion='2', ingestKey='other', platform='other', deviceId='other', apiUrl='https://other.test'}) do
      local other=make(h.files); other.core[key]=value; eq(other.core:getConfig('speed',0),0)
    end
    h.core:fetchConfig(); h.core:dropSession(); h.core.deviceId='new'; h.answer(200,doc())
    eq(h.core:getConfig('speed',0),0); eq(#h.ready,1)
    h.core.trackingEnabled=false; eq(h.core:fetchConfig(),false)
  end},
  {'malformed config and storage errors keep safe defaults',function()
    local h=make(); h.files['ravensight_config.json']='{'
    local invalid=doc(); invalid.experiments[1].variant='bad value'
    h.core:fetchConfig(); h.answer(200,invalid); eq(h.core:getConfig('speed',0),0)
    invalid=doc(); invalid.values.rules.__proto__={}; eq(Config.valid(invalid),false)
    h.core.storage.read=function() error('storage blocked') end
    h.core.storage.write=function() error('storage blocked') end
    h.core:fetchConfig(); h.answer(200,doc()); eq(h.core:getConfig('speed',0),3)
  end},
  {'session startup fetches config through the existing transport',function()
    local h=make(); h.core:onSessionResponse(201,json.encode({token='session',expiresIn=3600}),{},0)
    eq(#h.requests,1); assert(h.requests[1].req.url:find('/ingest/config?',1,true))
  end},
  {'web mailbox matches request identity and ignores old replies after consent changes',function()
    local mailbox, sent, now, ready=nil,{},0,{}
    local w=Web.new({time=function() return now end, print=function(line) table.insert(sent,json.decode(line:sub(#Web.TAG+1))) end,
      randomHex=function(n) return string.rep('b',n*2) end, readConfig=function() return mailbox end})
    w:on('config_ready',function(s) table.insert(ready,s) end)
    w:update(); eq(#sent,1); eq(sent[1].op,'config')
    mailbox=json.encode({id='wrong',values={speed=9},source='network'}); w:update(); eq(w:getConfig('speed',0),0)
    mailbox=json.encode({id=sent[1].id,values={speed=3},source='network'}); w:update(); eq(w:getConfig('speed',0),3); eq(ready[1],'network')
    w:fetchConfig(); local old=sent[#sent].id; w:setTrackingEnabled(false); w:setTrackingEnabled(true); w:update()
    mailbox=json.encode({id=old,values={speed=99},source='network'}); w:update(); eq(w:getConfig('speed',0),0)
    now=7; w:update(); eq(ready[#ready],'default')
  end},
}
