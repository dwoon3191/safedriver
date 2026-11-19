const assert=require('node:assert/strict');const {handler}=require('../netlify/functions/monthly.cjs');
process.env.SUPABASE_URL='https://example.test';process.env.SUPABASE_SERVICE_ROLE_KEY='server-only';
const call=(action,data={},token='session')=>handler({httpMethod:'POST',body:JSON.stringify({action,data,token})});
(async()=>{
 let calls=[];
 global.fetch=async(url,opts={})=>{calls.push([url,opts.body&&!Buffer.isBuffer(opts.body)?JSON.parse(opts.body):null]);return{ok:true,text:async()=>JSON.stringify({ok:true})}};
 // dispatch actions go to dp_api only, with the "dp_" prefix removed
 for(const [a,expect] of [['dp_upload','upload'],['dp_days','days'],['dp_day','day'],['dp_mine','mine']]){
  calls=[];const r=await call(a,{x:1});assert.equal(r.statusCode,200);assert.equal(calls.length,1);
  assert.match(calls[0][0],/\/rpc\/dp_api$/);assert.equal(calls[0][1].p_action,expect);assert.equal(calls[0][1].p_token,'session');
 }
 calls=[];await call('list');assert.match(calls[0][0],/\/rpc\/mr_api$/);
 calls=[];await call('link_all');assert.match(calls[0][0],/\/rpc\/mr_api2$/);
 calls=[];assert.equal((await call('dp_upload',{},'')).statusCode,400);assert.equal(calls.length,0);

 // download_bytes
 function files(bytes,{ok=true}={}){
  calls=[];
  global.fetch=async(url,opts={})=>{
   calls.push(url);
   if(url.includes('/rpc/mr_api'))return{ok:true,text:async()=>JSON.stringify({path:'u/r/a.pdf'})};
   if(url.includes('/object/sign/')&&opts.method==='POST')return{ok:true,text:async()=>JSON.stringify({signedURL:'/object/sign/driver-monthly-private/u/r/a.pdf?token=t'})};
   return{ok,arrayBuffer:async()=>bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength)};
  };
 }
 const pdf=Buffer.concat([Buffer.from('%PDF-1.4\n'),Buffer.alloc(100,1)]);
 files(pdf);let r=await call('download_bytes',{id:'1',kind:'pdf'});assert.equal(r.statusCode,200);
 assert.equal(Buffer.from(JSON.parse(r.body).base64,'base64').subarray(0,5).toString(),'%PDF-');
 files(pdf);r=await call('download_bytes',{id:'1',kind:'excel'});assert.equal(r.statusCode,400);assert.equal(calls.length,0);
 files(Buffer.from('<html>login</html>'));r=await call('download_bytes',{id:'1',kind:'pdf'});assert.equal(r.statusCode,400);
 files(Buffer.concat([Buffer.from('%PDF-'),Buffer.alloc(5*1024*1024)]));r=await call('download_bytes',{id:'1',kind:'pdf'});assert.equal(r.statusCode,400);
 files(pdf,{ok:false});r=await call('download_bytes',{id:'1',kind:'pdf'});assert.equal(r.statusCode,400);
 console.log('PASS: v2.2.0 gateway — dispatch routes to dp_api, download_bytes guards (kind, magic, size, failure)');
})().catch(e=>{console.error(e);process.exit(1);});
