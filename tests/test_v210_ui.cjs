// Mock-DOM test of assets/monthly.js (v2.1.0). No browser, no server. Verifies logic and markup only.
const vm=require('node:vm'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const code=fs.readFileSync(path.join(__dirname,'..','assets','monthly.js'),'utf8');
function env(role,handler,opts={}){
 const els={},reg={};const calls=[];const toasts=[],modals=[],opened=[],confirms=[];
 const mk=s=>els[s]||(els[s]={innerHTML:'',value:'',onclick:null,onchange:null,checked:false,disabled:false,files:[],textContent:''});
 const document={querySelector:mk,querySelectorAll:sel=>{
  const out=[];const html=(els['#page']||{}).innerHTML||'';
  let m=/^\[(data-[\w-]+)\]$/.exec(sel);
  if(m){const attr=m[1],key=attr.slice(5);const src=sel==='[data-map]'||sel==='[data-month]'?(els['#mrQueue']||{}).innerHTML||'':html;const re=new RegExp(attr+'="([^"]*)"','g');let x;
   while((x=re.exec(src+(els['#mrQueue']?els['#mrQueue'].innerHTML:'')))){const k=attr+'='+x[1];out.push(reg[k]||(reg[k]={dataset:{[key]:x[1]},onclick:null,onchange:null,disabled:false,value:''}));}
   return out;}
  if(sel==='.pq:checked'){const q=(els['#mrQueue']||{}).innerHTML||'';return [...q.matchAll(/class="pq" data-i="(\d+)" type="checkbox" checked>/g)].map(x=>({dataset:{i:x[1]}}));}
  return out;}};
 class FR{readAsDataURL(){this.result='data:application/pdf;base64,JVBERg==';setTimeout(()=>this.onload&&this.onload(),0);}}
 const loc={_href:'',set href(v){this._href=v;this.order=calls.length;},get href(){return this._href;}};
 const win={open:()=>{if(opts.blocked)return null;const w={location:'',opener:{},closed:false,close(){this.closed=true;}};opened.push(w);return w;}};
 const fetchMock=async(url,o)=>{const b=JSON.parse(o.body);calls.push(b);try{const v=await handler(b);return{ok:true,json:async()=>v};}catch(e){return{ok:false,json:async()=>({error:e.message})};}};
 const sb={window:win,document,fetch:fetchMock,confirm:m=>{confirms.push(m);return opts.confirm!==false;},alert(){},location:loc,URL,Blob,TextDecoder,FileReader:FR,console,setTimeout,Date};
 vm.createContext(sb);vm.runInContext(code,sb);
 const ctx={state:{session:{role,user_id:'me'}},token:()=>'tok',rpc:async()=>{},toast:(m,e)=>toasts.push([m,e]),openModal:h=>modals.push(h),closeModal(){}};
 return{MR:win.MonthlyReports,ctx,els,reg,calls,toasts,modals,opened,confirms,loc};
}
const tick=()=>new Promise(r=>setTimeout(r,20));
const rows=[{id:'r9',user_id:'me',month:'2026-09-01',etas_name:'본인',has_pdf:true,has_excel:true,verified:true,published:true,opened_at:null,acknowledged_at:null,revision:3},
            {id:'r8',user_id:'me',month:'2026-08-01',etas_name:'본인',has_pdf:true,has_excel:true,verified:true,published:true,opened_at:'2026-09-02T00:00:00Z',acknowledged_at:'2026-09-02T00:00:00Z',revision:1}];
(async()=>{
 // 1. driver home: latest big card, past list, no date search
 let e=env('driver',async b=>b.action==='list'?rows:b.action==='download'?{url:'https://x.test/a.pdf'}:{ok:true});
 await e.MR.render('dashboard',e.ctx);
 let h=e.els['#page'].innerHTML;
 assert.match(h,/2026년 9월 운행습관 리포트/);assert.match(h,/새 리포트가 있습니다/);assert.match(h,/data-open="r9"/);assert.match(h,/지난 리포트/);assert.match(h,/2026년 8월/);
 assert.doesNotMatch(h,/type="month"|시작월|종료월|내 종합진단표/);assert.doesNotMatch(h,/엑셀/);
 // 2. open without an in-app viewer (v2.2.0 keeps the link fallback): download -> open_ack(revision) -> same-tab link
 let e2=env('driver',async b=>b.action==='list'?rows:b.action==='download'?{url:'https://x.test/a.pdf'}:{ok:true});
 await e2.MR.render('dashboard',e2.ctx);await e2.reg['data-open=r9'].onclick();await tick();
 assert.deepEqual(e2.calls.map(c=>c.action).slice(0,3),['list','download','open_ack']);assert.equal(e2.calls[2].data.revision,3);
 assert.equal(e2.loc.href,'https://x.test/a.pdf');assert.equal(e2.calls[e2.loc.order-1].action,'open_ack');
 // 3. download failure records nothing and does not navigate
 e=env('driver',async b=>{if(b.action==='list')return rows;if(b.action==='download')throw Error('접근할 수 없는 보고서입니다.');return{ok:true};});
 await e.MR.render('dashboard',e.ctx);await e.reg['data-open=r9'].onclick();await tick();
 assert.equal(e.loc.href,'');assert.ok(!e.calls.some(c=>c.action==='open_ack'));assert.match(e.toasts.at(-1)[0],/접근/);
 // 4. open_ack failure does not block opening
 e=env('driver',async b=>{if(b.action==='list')return rows;if(b.action==='download')return{url:'https://x.test/c.pdf'};if(b.action==='open_ack')throw Error('자료가 교체되었습니다');return{}});
 await e.MR.render('dashboard',e.ctx);await e.reg['data-open=r9'].onclick();await tick();
 assert.equal(e.loc.href,'https://x.test/c.pdf');assert.ok(e.toasts.some(t=>/열람 기록 저장 실패/.test(t[0])));
 // 6. no reports
 e=env('driver',async b=>b.action==='list'?[]:{});await e.MR.render('dashboard',e.ctx);assert.match(e.els['#page'].innerHTML,/아직 확인할 리포트가 없습니다/);
 // 7. driver feedback wording
 e=env('driver',async b=>b.action==='messages'?[]:b.action==='list'?rows:{});await e.MR.render('feedback',e.ctx);await tick();
 h=e.els['#page'].innerHTML+e.els['#msgBody'].innerHTML;assert.match(h,/피드백 대화창/);assert.match(h,/보내기/);assert.doesNotMatch(h,/관리자 내부|msgKind|지도 이력/);
 // 8. admin drivers page: count + link-all flow
 const users=[{id:'u1',login_id:'a',display_name:'가나다',etas_name:null,employment:'재직',active:true},{id:'u2',login_id:'b',display_name:'라마바',etas_name:'라마바',employment:'재직',active:true},{id:'u3',login_id:'c',display_name:'사아자',etas_name:null,employment:'재직',active:true}];
 e=env('admin',async b=>b.action==='users'?users:b.action==='list'?[]:b.action==='link_all'?{linked:2,already:1,conflicts:['사아자'],empty:[]}:{});
 await e.MR.render('drivers',e.ctx);h=e.els['#page'].innerHTML;assert.match(h,/미연결 2명/);assert.match(h,/전체 연결/);
 await e.els['#linkAll'].onclick();await tick();assert.match(e.confirms[0],/2명/);assert.match(e.modals[0],/새로 연결 <b>2<\/b>명/);assert.match(e.modals[0],/사아자/);
 assert.equal(e.calls.filter(c=>c.action==='link_all').length,1);assert.equal(e.calls.filter(c=>c.action==='users').length,2);
 // 9. scan: exact, NFD file name, auto-link by account name, ambiguous, unknown
 const u2=[{id:'a1',display_name:'강명구',etas_name:null,employment:'재직',active:true,login_id:'a1'},{id:'a2',display_name:'강명구B',etas_name:'강명구B',employment:'재직',active:true,login_id:'a2'},
           {id:'d1',display_name:'김철수',etas_name:null,employment:'재직',active:true,login_id:'d1'},{id:'d2',display_name:'김철수',etas_name:null,employment:'재직',active:true,login_id:'d2'},
           {id:'n1',display_name:'이영희',etas_name:'이영희',employment:'재직',active:true,login_id:'n1'}];
 const f=n=>({name:n,size:1000,slice:()=>({arrayBuffer:async()=>new TextEncoder().encode('%PDF-1.4').buffer})});
 e=env('admin',async b=>b.action==='users'?u2:b.action==='list'?[]:b.action==='link_one'?{ok:true}:b.action==='upload'?{}:{});
 await e.MR.render('collector',e.ctx);
 e.els['#mrFiles']={files:[f('강명구(2026-09).pdf'),f('강명구B(2026-09).pdf'),f('이영희(2026-09).pdf'.normalize('NFD')),f('김철수(2026-09).pdf'),f('없는사람(2026-09).pdf')]};
 await e.els['#mrScan'].onclick();await tick();h=e.els['#mrQueue'].innerHTML;
 const states=[...h.matchAll(/<td>([^<]*)<\/td><\/tr>/g)].map(x=>x[1]);
 assert.match(states[0],/자동 연결/);assert.equal(states[1],'등록 대기');assert.equal(states[2],'등록 대기');assert.match(states[3],/기사 연결 확인 필요/);assert.match(states[4],/기사 연결 확인 필요/);
 // 10. upload: unlinked auto-matched account is linked first, then uploaded; linked ones upload directly
 await e.els['#mrUpload'].onclick();await tick();await tick();
 const seq=e.calls.map(c=>c.action+(c.data&&c.data.user_id?':'+c.data.user_id:''));
 const iLink=seq.indexOf('link_one:a1');assert.ok(iLink>=0);assert.equal(seq[iLink+1],'upload:a1');
 assert.equal(e.calls[iLink].data.etas_name,'강명구');assert.ok(seq.includes('upload:a2'));assert.ok(seq.includes('upload:n1'));
 assert.ok(!seq.some(x=>x.startsWith('upload:d1')||x.startsWith('upload:d2')));
 // 11. manual account choice for an unlinked account asks before linking; cancel stops that file
 e=env('admin',async b=>b.action==='users'?u2:b.action==='list'?[]:{},{confirm:false});
 await e.MR.render('collector',e.ctx);e.els['#mrFiles']={files:[f('다른이름(2026-09).pdf')]};await e.els['#mrScan'].onclick();await tick();
 e.reg['data-map=0'].value='d1';e.reg['data-map=0'].onchange();
 await e.els['#mrUpload'].onclick();await tick();
 assert.ok(!e.calls.some(c=>c.action==='link_one'||c.action==='upload'));assert.match(e.els['#mrQueue'].innerHTML,/연결을 취소/);
 console.log('PASS: v2.1.0 driver home, open+auto-ack (link fallback), feedback wording, link-all, filename matching, link-before-upload');
})().catch(x=>{console.error(x);process.exit(1);});
