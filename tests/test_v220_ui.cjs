// Mock-DOM test of v2.2.0 UI logic (dispatch.js, monthly.js openReport). No browser, no server.
const vm=require('node:vm'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const read=f=>fs.readFileSync(path.join(__dirname,'..','assets',f),'utf8');
const core=require('../assets/dispatch.js');
function env(role,handler,opts={}){
 const els={},reg={};const calls=[],toasts=[],confirms=[],viewer=[];
 const mk=s=>els[s]||(els[s]={innerHTML:'',value:'',onclick:null,onchange:null,oninput:null,checked:false,disabled:false,files:[],textContent:'',classList:{toggle(){},contains(){return false}}});
 const document={querySelector:mk,querySelectorAll:sel=>{
  const page=(els['#page']||{}).innerHTML||'';const prev=(els['#dpPreview']||{}).innerHTML||'';
  const grab=(src,re,fn)=>{const out=[];let m;while((m=re.exec(src))){const k=sel+'#'+m[1];out.push(reg[k]||(reg[k]=fn(m)));}return out;};
  if(sel==='.wk-tab')return grab(page,/class="wk-tab[^"]*" data-i="(\d)"/g,m=>({dataset:{i:m[1]},onclick:null}));
  if(sel==='[data-more]')return grab(page,/data-more="(\d+)"/g,m=>({dataset:{more:m[1]},onclick:null,textContent:''}));
  if(sel==='[data-open]')return grab(page,/data-open="([^"]+)"/g,m=>({dataset:{open:m[1]},onclick:null}));
  if(sel==='.dpPick')return grab(prev,/class="dpPick" data-i="(\d+)"/g,m=>({dataset:{i:m[1]},onchange:null}));
  if(sel==='.dpPick:checked')return [...prev.matchAll(/class="dpPick" data-i="(\d+)" checked/g)].map(m=>({dataset:{i:m[1]}}));
  return [];}};
 const fetchMock=async(url,o)=>{const b=JSON.parse(o.body);calls.push(b);try{const v=await handler(b);return{ok:true,json:async()=>v};}catch(x){return{ok:false,json:async()=>({error:x.message})};}};
 const loc={_h:'',set href(v){this._h=v;this.order=calls.length;},get href(){return this._h;}};
 const win={PdfViewer:opts.viewer===false?undefined:{open:async(b64,o)=>{viewer.push([b64,o]);if(opts.viewerFail)throw Error('viewer');return {};}}};
 if(opts.XLSX)win.XLSX=opts.XLSX;
 const sb={window:win,document,fetch:fetchMock,confirm:m=>{confirms.push(m);return opts.confirm!==false;},alert(){},location:loc,URL,Blob,TextDecoder,console,setTimeout,Date,XLSX:opts.XLSX};
 vm.createContext(sb);vm.runInContext(read('dispatch.js'),sb);vm.runInContext(read('monthly.js'),sb);
 const ctx={state:{session:{role,user_id:'me'}},token:()=>'tok',rpc:async()=>{},toast:(m,er)=>toasts.push([m,er]),openModal(){},closeModal(){}};
 return{win,ctx,els,reg,calls,toasts,confirms,viewer,loc};
}
const tick=()=>new Promise(r=>setTimeout(r,20));
const rep={id:'r9',user_id:'me',month:'2026-09-01',etas_name:'본인',has_pdf:true,has_excel:true,verified:true,published:true,opened_at:null,acknowledged_at:null,revision:3};
(async()=>{
 // ---- in-app viewer ----
 let e=env('driver',async b=>b.action==='list'?[rep]:b.action==='download_bytes'?{base64:'JVBERg=='}:{ok:true});
 await e.win.MonthlyReports.render('dashboard',e.ctx);await e.reg['[data-open]#r9'].onclick();await tick();
 assert.deepEqual(e.calls.map(c=>c.action).slice(0,3),['list','download_bytes','open_ack']);
 assert.equal(e.viewer.length,1);assert.equal(e.viewer[0][0],'JVBERg==');assert.match(e.viewer[0][1].title,/2026년 9월/);assert.equal(e.loc.href,'');
 assert.equal(e.calls[2].data.revision,3);
 // viewer failure -> falls back to the signed link, still records the open
 e=env('driver',async b=>b.action==='list'?[rep]:b.action==='download'?{url:'https://x.test/a.pdf'}:{ok:true},{viewerFail:true});
 await e.win.MonthlyReports.render('dashboard',e.ctx);await e.reg['[data-open]#r9'].onclick();await tick();
 assert.deepEqual(e.calls.map(c=>c.action).slice(0,4),['list','download_bytes','download','open_ack']);assert.equal(e.loc.href,'https://x.test/a.pdf');
 // download_bytes failure -> fallback too
 e=env('driver',async b=>{if(b.action==='list')return[rep];if(b.action==='download_bytes')throw Error('too big');if(b.action==='download')return{url:'https://x.test/b.pdf'};return{ok:true};});
 await e.win.MonthlyReports.render('dashboard',e.ctx);await e.reg['[data-open]#r9'].onclick();await tick();assert.equal(e.loc.href,'https://x.test/b.pdf');
 // ack failure after viewer does not break anything
 e=env('driver',async b=>{if(b.action==='list')return[rep];if(b.action==='download_bytes')return{base64:'x'};throw Error('stale');});
 await e.win.MonthlyReports.render('dashboard',e.ctx);await e.reg['[data-open]#r9'].onclick();await tick();assert.ok(e.toasts.some(t=>/열람 기록 저장 실패/.test(t[0])));

 // ---- driver: 오늘 근무 ----
 const today=core.seoulDate(0),d1=core.seoulDate(1),d2=core.seoulDate(2);
 const rr=[{seq:1,car:'경남71자1137',am_name:'허은민',am_time:'0513',pm_name:'이창호',pm_time:'1300'},{seq:2,car:'경남71자1364',am_name:'임석환',am_time:'0557',pm_name:'박대한',pm_time:'1322'}];
 const mine=(shift)=>({shift,route:'111',seq:1,car:'경남71자1137',am_name:'허은민',am_time:'0513',pm_name:'이창호',pm_time:'1300',route_rows:rr});
 const res={name:'허은민',days:[{date:today,status:'work',items:[mine('am')]},{date:d1,status:'off',items:[]},{date:d2,status:'unregistered'}]};
 e=env('driver',async b=>res);
 await e.win.Dispatch.render('work',e.ctx);
 assert.deepEqual(e.calls[0].data.dates,[today,d1,d2]);assert.equal(e.calls[0].action,'dp_mine');
 let h=e.els['#page'].innerHTML;
 assert.match(h,/오전반/);assert.match(h,/<b>111<\/b>번 노선/);assert.match(h,/배차순번 <b>1<\/b>/);assert.match(h,/차량 <b>1137<\/b>/);assert.match(h,/오전 5:13 출발/);
 assert.match(h,/같은 차 오후반: <b>이창호<\/b> · 오후 1:00 출발/);assert.match(h,/111번 노선 전체 보기/);assert.match(h,/class="me">허은민/);assert.doesNotMatch(h,/class="me">임석환/);
 e.reg['.wk-tab#1'].onclick();h=e.els['#page'].innerHTML;assert.match(h,/휴무/);assert.doesNotMatch(h,/오전 5:13/);
 e.reg['.wk-tab#2'].onclick();h=e.els['#page'].innerHTML;assert.match(h,/배차 미등록/);assert.doesNotMatch(h,/휴무입니다/);
 // pm shift shows pm time and 오전반 partner
 e=env('driver',async b=>({name:'이창호',days:[{date:today,status:'work',items:[mine('pm')]},{date:d1,status:'unregistered'},{date:d2,status:'unregistered'}]}));
 await e.win.Dispatch.render('work',e.ctx);h=e.els['#page'].innerHTML;
 assert.match(h,/wk-pm/);assert.match(h,/오후반/);assert.match(h,/오후 1:00 출발/);assert.match(h,/같은 차 오전반: <b>허은민<\/b> · 오전 5:13 출발/);
 // admin cannot use the driver screen path of dpadmin as a driver
 e=env('driver',async b=>({}));await assert.rejects(()=>e.win.Dispatch.render('dpadmin',e.ctx),/관리자 전용/);

 // ---- admin: upload ----
 const csvHead='일자,회사명,노선번호,운행순번,오전출발시간,오후출발시간,차량번호';
 const csv=[csvHead,'20261119,대운교통,106,1,0500,1247,경남71자1191','20261119,대운교통,73-1,1,0600,1400,경남71자1187','20261120,대운교통,106,1,0505,1250,경남71자1191'].join('\r\n');
 const xlsRows=[['업체명','운행일자','차량번호','노선명','운행순위','지원노선명','지원운행순위','오전승무원명','오후승무원명'],
  ['대운교통주식회사','2026-11-19','경남71자1191','106','1','','','박범진','손창규'],['대운교통주식회사','2026-11-19','경남71자1187','73-1','1','','','박정호','김종현'],['대운교통주식회사','2026-11-20','경남71자1191','106','1','','','박범진','손창규']];
 const buf=s=>Buffer.from(s,'utf8');
 const XLSX={read:()=>({SheetNames:['S'],Sheets:{S:{}}}),utils:{sheet_to_json:()=>xlsRows}};
 const files=[{name:'a.csv',arrayBuffer:async()=>{const b=buf(csv);return b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength);}},{name:'b.xls',arrayBuffer:async()=>new ArrayBuffer(8)}];
 const users=[{display_name:'박범진',etas_name:'박범진'},{display_name:'손창규',etas_name:null}];
 e=env('admin',async b=>{if(b.action==='dp_days')return[{date:'2026-11-20',rows:3,uploaded_at:'x'}];if(b.action==='users')return users;if(b.action==='dp_day')return{registered:true,rows:[{route:'106',seq:1,car:'경남71자1191',am_name:'박범진',am_time:'0500',pm_name:'손창규',pm_time:'1247'}],off:['강돈희']};if(b.action==='dp_upload')return{saved:b.data.days.map(d=>({date:d.date,rows:d.rows.length}))};return{};},{XLSX});
 e.els['#dpDate']={innerHTML:'',value:'2026-11-20',onchange:null};e.els['#dpSearch']={value:'',oninput:null};
 await e.win.Dispatch.render('dpadmin',e.ctx);await tick();
 assert.match(e.els['#dpTable'].innerHTML,/박범진/);assert.match(e.els['#dpOff'].innerHTML,/강돈희/);assert.match(e.els['#dpSummary'].innerHTML,/휴무자 <b>1<\/b>/);
 (e.els['#dpFiles']=e.els['#dpFiles']||{files:[]}).files=files;await e.els['#dpScan'].onclick();await tick();
 let p=e.els['#dpPreview'].innerHTML;
 assert.match(p,/11월 19일/);assert.match(p,/11월 20일/);assert.match(p,/이미 등록됨 — 덮어씁니다/);assert.match(p,/새로 저장/);
 assert.equal((p.match(/class="dpPick" data-i="\d+" checked/g)||[]).length,2);
 await e.els['#dpSave'].onclick();await tick();
 const up=e.calls.find(c=>c.action==='dp_upload');assert.equal(up.data.days.length,2);assert.equal(up.data.days[0].rows[1].route,'73-1');assert.equal(up.data.days[0].rows[1].am_name,'박정호');
 assert.equal(e.confirms.length,1);assert.match(e.confirms[0],/덮어씁니다/);assert.ok(e.toasts.some(t=>/2일치 배차를 저장/.test(t[0])));
 // overwrite declined -> nothing saved
 e=env('admin',async b=>{if(b.action==='dp_days')return[{date:'2026-11-19',rows:3}];if(b.action==='users')return users;if(b.action==='dp_day')return{registered:true,rows:[],off:[]};return{saved:[]};},{XLSX,confirm:false});
 await e.win.Dispatch.render('dpadmin',e.ctx);await tick();(e.els['#dpFiles']=e.els['#dpFiles']||{files:[]}).files=files;await e.els['#dpScan'].onclick();await tick();await e.els['#dpSave'].onclick();await tick();
 assert.ok(!e.calls.some(c=>c.action==='dp_upload'));
 // date-corrupted XLS: route becomes "1월-77" -> blocking error, checkbox disabled, nothing to save
 const badRows=xlsRows.map((r,i)=>i===2?r.map((v,k)=>k===3?'1월-77':v):r);
 e=env('admin',async b=>b.action==='dp_days'||b.action==='users'?[]:{registered:false},{XLSX:{read:XLSX.read,utils:{sheet_to_json:()=>badRows}}});
 await e.win.Dispatch.render('dpadmin',e.ctx);await tick();(e.els['#dpFiles']=e.els['#dpFiles']||{files:[]}).files=files;await e.els['#dpScan'].onclick();await tick();
 p=e.els['#dpPreview'].innerHTML;assert.match(p,/노선이 날짜처럼 바뀌었습니다/);assert.match(p,/오류가 있어 저장 불가/);
 // wrong files
 e=env('admin',async b=>b.action==='dp_days'||b.action==='users'?[]:{registered:false},{XLSX});
 await e.win.Dispatch.render('dpadmin',e.ctx);await tick();(e.els['#dpFiles']=e.els['#dpFiles']||{files:[]}).files=[files[0]];await e.els['#dpScan'].onclick();await tick();
 assert.match(e.els['#dpPreview'].innerHTML,/모두 선택해야 합니다/);
 console.log('PASS: v2.2.0 UI — in-app viewer + fallback, driver 오늘 근무 (work/off/unregistered/pm), admin upload preview/overwrite/guards');
})().catch(x=>{console.error(x);process.exit(1);});
