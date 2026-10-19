local Reports=require('ravensight.reports')
local json=require('ravensight.json')
local png='\137PNG\r\n\26\n'..'\0\0\0\13IHDR'..'\0\0\0\1\0\0\0\1'..string.rep('\0',9)
local function fixture()
 local requests={};local core={apiUrl='https://api.ravensight.io',sessionToken='session-fixture',deviceId='player',time=function()return 100000 end,randomHex=function()return string.rep('a',32)end,enabled=true}
 function core:isTrackingEnabled()return self.enabled end
 core.send=function(req,cb)requests[#requests+1]={req=req,cb=cb}end
 local reports=Reports.new(core,function()return string.rep('a',64)end)
 local input={clientId='fixture-001',message='A bug',consent=true,png=png}
 return reports,core,requests,input
end
return {
 {'explicit consent and bounded PNG required',function()
 local r,c,q,i=fixture();i.consent=false;assert(not r.prepare(i));i.consent=true;i.png='bad';assert(not r.prepare(i));i.png=png..string.rep('a',1000000);assert(not r.prepare(i));assert(#q==0)
 end},
 {'full upload uses session only for API and preserves binary PNG',function()
 local r,c,q,i=fixture();local handle=assert(r.prepare(i));local output,err
 assert(r.submit(handle,function(value,e)output=value;err=e end));assert(not r.submit(handle,function()end))
 assert(q[1].req.headers['X-Session-Token']=='session-fixture');assert(json.decode(q[1].req.body).sha256==string.rep('a',64))
 q[1].cb(201,json.encode({id=string.rep('b',24),status='pending'}));q[2].cb(200,json.encode({url='https://fixture.s3.us-east-1.amazonaws.com/',fields={key='fixture',Policy='signed'}}))
 assert(not q[3].req.headers['X-Session-Token']);assert(q[3].req.body:find(png,1,true));assert(q[3].req.body:find('name="file"',1,true)>q[3].req.body:find('name="key"',1,true))
 q[3].cb(204,'');q[4].cb(202,json.encode({id=string.rep('b',24),status='processing'}));assert(output.status=='processing' and not err)
 assert(r.submit(handle,function(value)output=value end));assert(q[5].req.method=='GET');q[5].cb(200,json.encode({id=string.rep('b',24),status='complete'}));assert(output.status=='complete')
 end},
 {'same session retry after ambiguous upload never creates another report',function()
 local r,c,q,i=fixture();local h=assert(r.prepare(i));local err;r.submit(h,function(_,e)err=e end);q[1].cb(201,json.encode({id=string.rep('b',24),status='pending'}));q[2].cb(200,json.encode({url='https://fixture.s3.amazonaws.com',fields={key='x'}}));q[3].cb(0,'');assert(err=='upload_failed');r.submit(h,function()end);assert(q[4].req.method=='GET');c.sessionToken='changed';q[4].cb(200,'{}');assert(not r.submit(h,function()end))
 end},
 {'revocation stops workflow and hostile upload grants fail closed',function()
 local r,c,q,i=fixture();local h=assert(r.prepare(i));local err;r.submit(h,function(_,e)err=e end);c.enabled=false;q[1].cb(201,json.encode({id=string.rep('b',24),status='pending'}));assert(err=='report_session_unavailable' and #q==1)
 for _,url in ipairs({'http://example.com','https://localhost','https://fixture.s3.amazonaws.com@evil.test/'})do
 r,c,q,i=fixture();h=assert(r.prepare(i));r.submit(h,function(_,e)err=e end);q[1].cb(201,json.encode({id=string.rep('b',24),status='pending'}));q[2].cb(200,json.encode({url=url,fields={key='x'}}));assert(err=='invalid_upload' and #q==2)
 end
 end},
}
