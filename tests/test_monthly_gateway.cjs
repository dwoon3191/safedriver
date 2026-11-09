const assert=require('node:assert/strict');const {handler}=require('../netlify/functions/monthly.cjs');
process.env.SUPABASE_URL='https://example.test';process.env.SUPABASE_SERVICE_ROLE_KEY='server-only';
const call=(action,data={},token='session')=>handler({httpMethod:'POST',body:JSON.stringify({action,data,token})});
(async()=>{
 let requests=[];global.fetch=async(url,opts)=>{requests.push([url,opts]);const body=JSON.parse(opts.body);if(body.p_action==='file_get')return {ok:false,text:async()=>JSON.stringify({message:'접근 거절'})};return{ok:true,text:async()=>JSON.stringify([])}};
 assert.equal((await call('file_commit')).statusCode,400);assert.equal(requests.length,0);
 assert.equal((await call('download',{id:'other',kind:'pdf'})).statusCode,400);assert.equal(requests.length,1);assert.match(requests[0][0],/rpc\/mr_api/);
 requests=[];assert.equal((await call('upload',{kind:'pdf',ext:'pdf',base64:Buffer.from('fake').toString('base64')})).statusCode,400);assert.equal(requests.length,0);
 let commits=0;requests=[];global.fetch=async(url,opts)=>{requests.push(url);let out={};if(url.includes('/rpc/')){const b=JSON.parse(opts.body);if(b.p_action==='prepare')out={id:'r',user_id:'u',revision:4};if(b.p_action==='file_commit'){commits++;assert.equal(b.p_data.revision,4);assert.equal(b.p_data.hash.length,64);out={ok:true};}}return{ok:true,text:async()=>JSON.stringify(out)}};
 assert.equal((await call('upload',{user_id:'u',month:'2026-01-01',kind:'pdf',ext:'pdf',base64:Buffer.from('%PDF-1.4 mock').toString('base64')})).statusCode,200);assert.equal(commits,1);assert.equal(requests.length,3);
 global.fetch=async(url,opts)=>({ok:true,text:async()=>JSON.stringify(url.includes('/rpc/')?{path:'u/r/file.pdf'}:{signedURL:'/object/sign/driver-monthly-private/u/r/file.pdf?token=test'})});
 const dl=await call('download',{id:'r',kind:'pdf'});assert.equal(JSON.parse(dl.body).url,'https://example.test/storage/v1/object/sign/driver-monthly-private/u/r/file.pdf?token=test');
 console.log('PASS: gateway allowlist, authorization-before-signing, signature checks, upload commit, signed URL');
})();
