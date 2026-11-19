const assert=require('node:assert/strict');const {handler}=require('../netlify/functions/monthly.cjs');
process.env.SUPABASE_URL='https://example.test';process.env.SUPABASE_SERVICE_ROLE_KEY='server-only';
const call=(action,data={},token='session')=>handler({httpMethod:'POST',body:JSON.stringify({action,data,token})});
(async()=>{
 let urls=[];global.fetch=async(url,opts)=>{urls.push([url,JSON.parse(opts.body)]);return{ok:true,text:async()=>JSON.stringify({ok:true})}};
 for(const a of ['link_all','link_one','open_ack']){urls=[];const r=await call(a,{x:1});assert.equal(r.statusCode,200);assert.equal(urls.length,1);assert.match(urls[0][0],/\/rpc\/mr_api2$/);assert.equal(urls[0][1].p_action,a);assert.equal(urls[0][1].p_token,'session');}
 urls=[];await call('list');assert.match(urls[0][0],/\/rpc\/mr_api$/);
 urls=[];assert.equal((await call('drop_everything')).statusCode,400);assert.equal(urls.length,0);
 urls=[];assert.equal((await call('link_all',{},'')).statusCode,400);assert.equal(urls.length,0);
 console.log('PASS: v2.1.0 gateway routes new actions to mr_api2 only; old actions unchanged; unknown/empty-token rejected');
})();
