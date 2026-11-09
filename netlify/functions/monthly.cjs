const {createHash,randomUUID}=require('node:crypto');
const ALLOWED=new Set(['list','users','user_save','user_delete','prepare','verify','publish','unpublish','ack','opened','messages','message_add','upload','download']);
const BUCKET='driver-monthly-private';
exports.handler=async event=>{
 const reply=(statusCode,body)=>({statusCode,headers:{'Content-Type':'application/json','Cache-Control':'no-store'},body:JSON.stringify(body)});
 if(event.httpMethod!=='POST')return reply(405,{error:'POST required'});
 try{
  const base=process.env.SUPABASE_URL?.replace(/\/$/,''); const key=process.env.SUPABASE_SERVICE_ROLE_KEY;
  if(!base||!key)return reply(503,{error:'Netlify 서버 환경변수 설정이 필요합니다. 설명서를 확인하세요.'});
  const {token,action,data={}}=JSON.parse(event.body||'{}');
  if(typeof token!=='string'||!token||!ALLOWED.has(action))return reply(400,{error:'잘못된 요청'});
  async function request(path,body,method='POST',headers={}){
   const res=await fetch(base+path,{method,headers:{apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json',...headers},body:Buffer.isBuffer(body)?body:JSON.stringify(body)});
   const txt=await res.text(); let val;try{val=JSON.parse(txt);}catch{val={message:txt};}
   if(!res.ok)throw new Error(val.message||val.error||`HTTP ${res.status}`);return val;
  }
  const rpc=(a,d)=>request('/rest/v1/rpc/mr_api',{p_token:token,p_action:a,p_data:d});
  if(action==='upload'){
   const kind=data.kind,ext=String(data.ext||'').toLowerCase();
   if(!((kind==='pdf'&&ext==='pdf')||(kind==='excel'&&['xls','xlsx'].includes(ext))))throw Error('지원 파일: PDF, XLS, XLSX');
   const b=Buffer.from(String(data.base64||''),'base64');
   if(!b.length||b.length>3*1024*1024)throw Error('파일당 최대 3MB입니다. 초과 자료는 별도 확인이 필요합니다.');
   const ok=ext==='pdf'?b.subarray(0,5).toString()==='%PDF-':ext==='xls'?b.subarray(0,8).toString('hex')==='d0cf11e0a1b11ae1':b.subarray(0,4).toString('hex')==='504b0304';
   if(!ok)throw Error('확장자와 파일 형식이 일치하지 않습니다.');
   const r=await rpc('prepare',{user_id:data.user_id,month:data.month});
   const hash=createHash('sha256').update(b).digest('hex');
   if(r[kind+'_hash']===hash)return reply(200,{duplicate:true});
   const path=`${r.user_id}/${r.id}/${randomUUID()}.${ext}`;
   await request(`/storage/v1/object/${BUCKET}/${path}`,b,'POST',{'Content-Type':ext==='pdf'?'application/pdf':ext==='xlsx'?'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':'application/vnd.ms-excel'});
   try{const result=await rpc('file_commit',{id:r.id,revision:r.revision,kind,ext,path,hash});return reply(200,result);}
   catch(e){await request(`/storage/v1/object/${BUCKET}`,{prefixes:[path]},'DELETE').catch(()=>{});throw e;}
  }
  if(action==='download'){
   if(!['pdf','excel'].includes(data.kind))throw Error('파일 종류 오류');
   const r=await rpc('file_get',data);if(!r.path)throw Error('등록된 파일이 없습니다.');
   const signed=await request(`/storage/v1/object/sign/${BUCKET}/${r.path}`,{expiresIn:60});
   const url=signed.signedURL||signed.signedUrl;if(!url)throw Error('파일 링크 생성 실패');
   return reply(200,{url:base+'/storage/v1'+url});
  }
  return reply(200,await rpc(action,data));
 }catch(e){return reply(400,{error:String(e.message).slice(0,500)});}
};
