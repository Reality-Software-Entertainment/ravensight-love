-- Explicit caller-supplied PNG reports. Never captures a window or queues analytics.
local prefix = (...):gsub('reports$', '')
local json = require(prefix .. 'json')
local Reports = {}
local categories = {bug=true,suggestion=true,complaint=true,praise=true,playtest=true,other=true}
local function validPng(png)
  if type(png) ~= 'string' or #png < 33 or #png > 1000000 or png:sub(1,8) ~= '\137PNG\r\n\26\n' or png:sub(13,16) ~= 'IHDR' then return false end
  local function number(at) local a,b,c,d=png:byte(at,at+3);return ((a*256+b)*256+c)*256+d end
  return number(9)==13 and number(17)>0 and number(21)>0 and number(17)<=1600 and number(21)<=1600
end
function Reports.new(core, hash)
  local states=setmetatable({}, {__mode='k'})
  local function active(state)
    return core:isTrackingEnabled() and core.sessionToken ~= '' and (not state.token or (state.token==core.sessionToken and state.device==core.deviceId))
  end
  local function prepare(input)
    if type(input)~='table' or input.consent~=true then return nil,'report_consent_required' end
    if type(input.clientId)~='string' or #input.clientId<8 or #input.clientId>80 or input.clientId:find('[^%w_-]') then return nil,'invalid_report' end
    if not validPng(input.png) then return nil,'invalid_png' end
    local payload={clientId=input.clientId,capturedAt=input.capturedAt or core.time(),category=input.category or 'other',source=input.source or 'player',image=true,bytes=#input.png}
    if not categories[payload.category] or (payload.source~='player' and payload.source~='tester') or type(payload.capturedAt)~='number' or payload.capturedAt%1~=0 or payload.capturedAt<core.time()-86400 or payload.capturedAt>core.time()+60 then return nil,'invalid_report' end
    for key,max in pairs({message=500,level=100,expected=500,steps=1000,frequency=80}) do
      local value=input[key] or ''
      if type(value)~='string' or #value>max or (key=='message' and not value:find('%S')) then return nil,'invalid_report' end
      payload[key]=value
    end
    local ok,digest=pcall(hash,input.png)
    if not ok or type(digest)~='string' or #digest~=64 or digest:find('[^a-f0-9]') then return nil,'hash_unavailable' end
    payload.sha256=digest
    local handle={}
    states[handle]={payload=json.encode(payload),png=input.png}
    return handle
  end
  local function submit(handle,callback)
    local state=states[handle]
    if not state or type(callback)~='function' then return false,'invalid_report' end
    if state.pending then return false,'report_pending' end
    if not active(state) then return false,'report_session_unavailable' end
    state.token=state.token or core.sessionToken;state.device=state.device or core.deviceId;state.pending=true
    local function finish(value,err) state.pending=false;callback(value,err) end
    local function send(path,body,next)
      if not active(state) then finish(nil,'report_session_unavailable');return end
      core.send({method=body and 'POST' or 'GET',url=core.apiUrl..'/api/v1'..path,headers={['Content-Type']='application/json',['X-Session-Token']=state.token},body=body,timeout=30,maxResponseBytes=65536},function(status,response)
        if not active(state) then finish(nil,'report_session_unavailable');return end
        if type(response)~='string' or #response>65536 or status<200 or status>=300 then finish(nil,'report_request_failed');return end
        local value=json.decode(response)
        if type(value)~='table' then finish(nil,'invalid_response');return end
        next(value)
      end)
    end
    local function accept(value)
      if type(value.id)~='string' or not value.id:match('^[a-f0-9]+$') or #value.id~=24 or not ({pending=true,processing=true,complete=true,canceled=true})[value.status] then finish(nil,'invalid_response');return end
      if state.id and state.id~=value.id then finish(nil,'invalid_response');return end
      state.id=value.id
      if value.status~='pending' then finish(value);return end
      local function finalize() send('/reports/'..state.id..'/finalize','{}',function(result) if result.status=='pending' then finish(nil,'invalid_response') else accept(result) end end) end
      if state.uploaded then finalize();return end
      send('/reports/'..state.id..'/upload','{}',function(grant)
        if type(grant.url)~='string' or not grant.url:match('^https://[%w%.%-]+%.s3[%w%.%-]*%.amazonaws%.com/?$') or type(grant.fields)~='table' then finish(nil,'invalid_upload');return end
        local boundary='ravensight_'..state.payload:sub(-20):gsub('[^%w]','')..core.randomHex(16)
        if state.png:find(boundary,1,true) then finish(nil,'invalid_upload');return end
        local chunks,bytes,count={},0,0
        for key,value in pairs(grant.fields) do
          if type(key)~='string' or not key:match('^[%w_-]+$') or #key>100 or key=='file' or type(value)~='string' or #value>16384 or value:find('[\r\n]') then finish(nil,'invalid_upload');return end
          count=count+1;bytes=bytes+#key+#value
          if count>30 or bytes>32768 then finish(nil,'invalid_upload');return end
          chunks[#chunks+1]='--'..boundary..'\r\nContent-Disposition: form-data; name="'..key..'"\r\n\r\n'..value..'\r\n'
        end
        if count==0 then finish(nil,'invalid_upload');return end
        chunks[#chunks+1]='--'..boundary..'\r\nContent-Disposition: form-data; name="file"; filename="screenshot.png"\r\nContent-Type: application/octet-stream\r\n\r\n'..state.png..'\r\n--'..boundary..'--\r\n'
        if not active(state) then finish(nil,'report_session_unavailable');return end
        core.send({method='POST',url=grant.url,headers={['Content-Type']='multipart/form-data; boundary='..boundary},body=table.concat(chunks),timeout=30,maxResponseBytes=65536},function(status)
          if not active(state) then finish(nil,'report_session_unavailable');return end
          if status<200 or status>=300 then finish(nil,'upload_failed');return end
          state.uploaded=true;finalize()
        end)
      end)
    end
    local body
    if not state.id then body=state.payload end
    send(state.id and '/reports/'..state.id or '/reports',body,accept)
    return true
  end
  return {prepare=prepare,submit=submit}
end
return Reports
