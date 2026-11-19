/* Monthly report workspace. Uses the existing login; server verifies every request. */
window.MonthlyReports=(()=>{
 let ctx,users=[],rows=[],pending=[],owner="",epoch=0;
 const e=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const $=s=>document.querySelector(s);
 const admin=()=>ctx.state.session.role==='admin';
 const api=async(action,data={})=>{const r=await fetch('/.netlify/functions/monthly',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:ctx.token(),action,data})});const v=await r.json();if(!r.ok)throw Error(v.error||'요청 실패');return v;};
 const run=fn=>async ev=>{const b=ev?.currentTarget;if(b)b.disabled=true;try{await fn(ev);}catch(x){ctx.toast(x.message,true);}finally{if(b)b.disabled=false;}};
 const status=r=>r.acknowledged_at?'확인 완료':r.opened_at?'열람':r.published?'미열람':r.verified?'게시 대기':'검증 대기';
 const norm=x=>String(x??'').normalize('NFC').trim();
 const monthLabel=m=>{const [y,mo]=String(m).slice(0,7).split('-');return `${y}년 ${Number(mo)}월`;};
 const opts=(selected)=>users.map(u=>`<option value="${u.id}" ${u.id===selected?'selected':''}>${e(u.etas_name||u.display_name)}${u.etas_name?'':' (공단이름 미연결)'} · ${e(u.employment)}${u.active?'':' · 접속중단'}</option>`).join('');
 const csv=(name,data)=>{const text='\ufeff'+data.map(r=>r.map(x=>'"'+String(x??'').replace(/^[=+@-]/,"'$&").replaceAll('"','""')+'"').join(',')).join('\r\n');save(name,new Blob([text],{type:'text/csv;charset=utf-8'}));};
 function save(name,blob){const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),3000);}
 async function render(page,c){ctx=c;const seq=++epoch,auth=ctx.token(),who=ctx.state.session.user_id;
  if(owner!==who){users=[];rows=[];pending=[];owner=who;}
  if(!admin()&&['drivers','collector'].includes(page))throw Error('관리자 전용 화면입니다.');
  const [reportsData,usersData]=await Promise.all([api('list'),admin()?api('users'):Promise.resolve([])]);
  if(seq!==epoch||auth!==ctx.token())return;
  rows=reportsData;users=usersData;
  if(page==='drivers')return drivers();
  if(page==='collector')return collection();
  if(page==='feedback')return feedback();
  return reports(page);
 }
 function reports(page){
  if(!admin())return driverHome(page);
  $('#page').innerHTML=`<div class="card"><h3>운행습관 리포트 관리</h3><p>공단 원본 PDF · 월별 보관 · 열람 및 확인 기록</p><div class="toolbar"><label>시작월<input id="mrFrom" type="month"></label><label>종료월<input id="mrTo" type="month"></label>${admin()?`<label>기사<select id="mrUser"><option value="">전체</option>${opts()}</select></label>`:''}<button id="mrFilter" class="btn secondary">조회</button></div><div id="mrSummary"></div></div>${admin()?`<div class="card"><div class="toolbar"><button id="mrVerify" class="btn secondary">③ 선택 자료 내용·계정 검증 완료</button><button id="mrPublish" class="btn primary">④ 선택 자료 게시</button><button id="mrUnpublish" class="btn danger">선택 게시 취소</button><button id="mrExport" class="btn secondary">확인현황 CSV</button></div><p class="small">PDF·엑셀을 열어 기사명과 분석월을 직접 대조한 뒤 검증 완료를 누르세요. 자동 내용 검증 완료를 의미하지 않습니다.</p></div>`:''}<div class="card"><div class="table-wrap" id="mrTable"></div></div>`;
  function shown(){return rows.filter(r=>(!$('#mrFrom').value||r.month.slice(0,7)>=$('#mrFrom').value)&&(!$('#mrTo').value||r.month.slice(0,7)<=$('#mrTo').value)&&(!$('#mrUser')?.value||r.user_id===$('#mrUser').value));}
  function draw(){const list=shown();$('#mrSummary').textContent=`총 ${list.length}건 · 게시 ${list.filter(r=>r.published).length}건 · 확인 완료 ${list.filter(r=>r.acknowledged_at).length}건`;
   $('#mrTable').innerHTML=`<table><thead><tr>${admin()?'<th><input type="checkbox" id="mrAll" aria-label="전체 선택"></th>':''}<th>기사</th><th>분석월</th><th>파일</th><th>상태</th><th>확인</th></tr></thead><tbody>${list.map(r=>`<tr>${admin()?`<td><input type="checkbox" class="mrCheck" value="${r.id}"></td>`:''}<td>${e(r.etas_name)}</td><td>${e(r.month.slice(0,7))}</td><td>${r.has_pdf?`<button class="btn secondary" data-open="${r.id}" data-kind="pdf">PDF 열기</button>`:'PDF 없음'} ${admin()&&r.has_excel?`<button class="btn secondary" data-open="${r.id}" data-kind="excel">엑셀</button>`:''}</td><td>${status(r)}</td><td>${!admin()?`<button class="btn primary" data-ack="${r.id}">확인 완료</button>`:e(r.acknowledged_at?new Date(r.acknowledged_at).toLocaleString('ko-KR'):'-')}</td></tr>`).join('')||'<tr><td colspan="6">해당 월 자료가 없습니다.</td></tr>'}</tbody></table>`;
   if($('#mrAll'))$('#mrAll').onchange=ev=>document.querySelectorAll('.mrCheck').forEach(x=>x.checked=ev.target.checked);
   document.querySelectorAll('[data-open]').forEach(b=>b.onclick=run(async()=>{const w=window.open('about:blank','_blank');if(w)w.opener=null;try{const x=await api('download',{id:b.dataset.open,kind:b.dataset.kind});if(!w)throw Error('팝업을 허용한 후 다시 여세요.');w.location=x.url;const r=rows.find(r=>r.id===b.dataset.open);if(!admin())await api('opened',{id:r.id,revision:r.revision});}catch(err){w?.close();throw err;}}));
   document.querySelectorAll('[data-ack]').forEach(b=>b.onclick=run(async()=>{const r=rows.find(r=>r.id===b.dataset.ack);await api('ack',{id:r.id,revision:r.revision});await render(page,ctx);}));
  }draw();$('#mrFilter').onclick=draw;
  if(admin()){
   const batch=action=>run(async()=>{const ids=[...document.querySelectorAll('.mrCheck:checked')].map(x=>x.value);if(!ids.length)throw Error('자료를 선택하세요.');if(!confirm(action==='verify'?'선택 자료의 PDF·엑셀 내용과 기사 계정·분석월을 직접 확인했습니까?':'선택한 '+ids.length+'건을 처리할까요?'))return;let errors=[];for(const id of ids)try{await api(action,{id,revision:rows.find(r=>r.id===id).revision});}catch(x){errors.push(id+': '+x.message);}await render(page,ctx);if(errors.length)alert(errors.join('\n'));});
   $('#mrVerify').onclick=batch('verify');$('#mrPublish').onclick=batch('publish');$('#mrUnpublish').onclick=batch('unpublish');
   $('#mrExport').onclick=()=>csv('월별_확인현황.csv',[['기사','분석월','상태','열람일','확인일'],...shown().map(r=>[r.etas_name,r.month,status(r),r.opened_at,r.acknowledged_at])]);
  }
 }
 async function openReport(id,page){
  const r=rows.find(x=>x.id===id);if(!r)throw Error('리포트를 찾을 수 없습니다. 화면을 새로고침하세요.');
  const ack=async()=>{if(!admin()){try{await api('open_ack',{id,revision:r.revision});}catch(err){ctx.toast('열람 기록 저장 실패: '+err.message,true);}}};
  // 1) Show the PDF inside the app (no PDF app, no new tab). 2) If that fails for any reason, fall back to the signed link.
  if(window.PdfViewer){
   try{
    const x=await api('download_bytes',{id,kind:'pdf'});
    await window.PdfViewer.open(x.base64,{title:monthLabel(r.month)+' 운행습관 리포트',onClose:()=>{render(page,ctx).catch(()=>{});}});
    await ack();return;
   }catch(err){console.warn('in-app viewer failed, using link',err);}
  }
  const x=await api('download',{id,kind:'pdf'});
  await ack(); // record before leaving this page
  location.href=x.url;
 }
 function driverHome(page){
  const list=[...rows].sort((a,b)=>String(b.month).localeCompare(String(a.month)));
  const latest=list[0];
  const ackText=r=>r.acknowledged_at?`확인 완료 (${e(new Date(r.acknowledged_at).toLocaleDateString('ko-KR'))})`:'아직 열어보지 않았습니다';
  const body=!latest?`<section class="dr-card"><div class="dr-title">아직 확인할 리포트가 없습니다</div><p class="dr-text">새 리포트가 올라오면 이 화면에 표시됩니다.</p></section>`
   :`<section class="dr-card">${latest.acknowledged_at?'':'<div class="dr-new">새 리포트가 있습니다</div>'}<div class="dr-title">${e(monthLabel(latest.month))} 운행습관 리포트</div><p class="dr-text ${latest.acknowledged_at?'dr-ok':''}">${ackText(latest)}</p>${latest.has_pdf?`<button class="dr-btn" data-open="${latest.id}">리포트 보기</button>`:'<p class="dr-text">리포트 파일을 준비 중입니다.</p>'}</section>`;
  const past=list.slice(1).filter(r=>r.has_pdf);
  $('#page').innerHTML=`<div class="dr-wrap">${body}${past.length?`<div class="dr-sub">지난 리포트</div>${past.map(r=>`<button class="dr-row" data-open="${r.id}"><span>${e(monthLabel(r.month))}</span><span class="dr-state ${r.acknowledged_at?'ok':''}">${r.acknowledged_at?'확인 완료':'눌러서 보기'}</span></button>`).join('')}`:''}</div>`;
  document.querySelectorAll('[data-open]').forEach(b=>b.onclick=run(()=>openReport(b.dataset.open,page)));
 }

 function collection(){
  $('#page').innerHTML=`<div class="card"><h3>① PC에서 공단 자료 수집</h3><p>PC의 <b>공단 수집기(run.bat)</b>를 실행하세요. 명부 불러오기 → 크롬으로 공단 열기·로그인 → 명단 점검 → 1명 시험 → 수집 → 실패·미완료 건 확인 순서입니다.</p><p class="notice warn">수집이 끝난 PDF·엑셀 파일을 아래에서 등록합니다. 수동으로 받은 자료도 같은 방법으로 등록할 수 있습니다. 먼저 기사 계정 화면에서 공단 이름 연결 상태를 확인하세요.</p><button id="rosterExport" class="btn secondary">수집용 기사명부 내보내기</button></div><div class="card"><h3>② PDF·엑셀 검증 및 웹 등록</h3><p>파일명: 기사명(YYYY-MM).pdf / .xls / .xlsx. 여러 파일을 선택할 수 있습니다. 로컬 원본은 그대로 유지합니다. 파일당 3MB 이하.</p><input type="file" id="mrFiles" multiple accept=".pdf,.xls,.xlsx"><div class="toolbar"><button id="mrScan" class="btn secondary">선택 파일 검사·계정 연결</button><button id="mrUpload" class="btn primary">체크한 정상 파일 웹 등록</button><button id="mrFailures" class="btn secondary">확인 필요 목록 CSV</button></div><p>파일명에서 기사명을 찾지 못하면 계정을 직접 선택하세요. 내용 대조는 등록 후 월별 보고서 화면에서 진행합니다.</p><div class="table-wrap" id="mrQueue"></div></div>`;
  $('#rosterExport').onclick=()=>save('기사명부.json',new Blob([JSON.stringify(users.map(u=>({id:u.id,name:u.etas_name||u.display_name,employment:u.employment,effective_date:u.effective_date,active:u.active})),null,2)],{type:'application/json'}));
  const draw=()=>{$('#mrQueue').innerHTML=`<table><tr><th>선택</th><th>파일</th><th>기사 연결</th><th>분석월</th><th>상태</th></tr>${pending.map((p,i)=>`<tr><td><input class="pq" data-i="${i}" type="checkbox" ${p.ok&&!p.state.startsWith('등록 완료')?'checked':''}></td><td>${e(p.file.name)}</td><td><select data-map="${i}"><option value="">선택</option>${opts(p.user)}</select></td><td><input type="month" data-month="${i}" value="${e(p.month)}"></td><td>${e(p.state)}</td></tr>`).join('')}</table>`;
   document.querySelectorAll('[data-map]').forEach(x=>{x.value=pending[x.dataset.map].user||'';x.onchange=()=>pending[x.dataset.map].user=x.value;});document.querySelectorAll('[data-month]').forEach(x=>x.onchange=()=>pending[x.dataset.month].month=x.value);
  };
  $('#mrScan').onclick=run(async()=>{pending=[];for(const file of $('#mrFiles').files){const m=file.name.match(/^(.+)\((\d{4}-(?:0[1-9]|1[0-2]))\)\.(pdf|xls|xlsx)$/i);const ext=file.name.split('.').pop().toLowerCase();let ok=false;try{const b=new Uint8Array(await file.slice(0,8).arrayBuffer());const hex=[...b].map(v=>v.toString(16).padStart(2,'0')).join('');ok=file.size>0&&file.size<=3*1024*1024&&(ext==='pdf'?new TextDecoder().decode(b).startsWith('%PDF-'):ext==='xls'?hex==='d0cf11e0a1b11ae1':ext==='xlsx'&&hex.startsWith('504b0304'));}catch{}const base=norm(m?.[1]);let matches=users.filter(u=>norm(u.etas_name)===base);let willLink=false;
   if(!matches.length&&base){const cand=users.filter(u=>!u.etas_name&&norm(u.display_name)===base);if(cand.length===1){matches=cand;willLink=true;}}
   pending.push({file,ext,base,month:m?.[2]||'',user:matches.length===1?matches[0].id:'',ok,state:!ok?'파일 형식/용량 확인 필요':matches.length!==1?'기사 연결 확인 필요':willLink?'등록 대기 (공단 이름 자동 연결)':'등록 대기'});}draw();});
  $('#mrUpload').onclick=run(async()=>{const selected=[...document.querySelectorAll('.pq:checked')].map(x=>Number(x.dataset.i));for(const i of selected){const p=pending[i];try{if(!p.ok||!p.user||!/^\d{4}-(0[1-9]|1[0-2])$/.test(p.month))throw Error('파일·기사·분석월 확인 필요');const acct=users.find(x=>x.id===p.user);
    if(acct&&!acct.etas_name){if(!p.base)throw Error('파일명에서 기사명을 읽지 못해 공단 이름을 연결할 수 없습니다.');
     if(norm(acct.display_name)!==p.base&&!confirm(`계정 '${acct.display_name}'에 공단 이름 '${p.base}'을(를) 연결하고 등록할까요?`))throw Error('공단 이름 연결을 취소했습니다.');
     await api('link_one',{user_id:acct.id,etas_name:p.base});acct.etas_name=p.base;}
    p.state='등록 중';draw();const b64=await new Promise((res,rej)=>{const f=new FileReader();f.onload=()=>res(f.result.split(',')[1]);f.onerror=rej;f.readAsDataURL(p.file);});const r=await api('upload',{kind:p.ext==='pdf'?'pdf':'excel',ext:p.ext,user_id:p.user,month:p.month+'-01',base64:b64});p.state=r.duplicate?'등록 완료 (동일 원본)':'등록 완료';}catch(err){p.state='실패: '+err.message;}draw();}ctx.toast('등록 처리가 끝났습니다. 월별 보고서에서 내용을 검증하세요.');});
  $('#mrFailures').onclick=()=>csv('등록_확인필요.csv',[['파일','기사계정','분석월','상태'],...pending.filter(p=>!p.state.startsWith('등록 완료')).map(p=>[p.file.name,p.user,p.month,p.state])]);draw();
 }
 function drivers(){
  $('#page').innerHTML=`<div class="card"><h3>기사 계정·공단 이름 연결</h3><p>계정 삭제는 접속 중단 방식입니다. 과거 보고서·피드백은 보존됩니다. 휴직 여부와 접속 허용은 별개입니다.</p><p><b>공단 이름 미연결 ${users.filter(u=>!u.etas_name).length}명</b> / 전체 ${users.length}명</p><button id="newDriver" class="btn primary">신규 기사 등록</button> <button id="linkAll" class="btn secondary">전체 연결 (미연결 기사)</button><div class="table-wrap"><table><tr><th>기사 / 로그인 ID</th><th>공단 이름</th><th>재직</th><th>접속</th><th>관리</th></tr>${users.map(u=>`<tr><td>${e(u.display_name)} / ${e(u.login_id)}</td><td>${e(u.etas_name||'미연결')}</td><td>${e(u.employment)}</td><td>${u.active?'허용':'중단'}</td><td><button class="btn secondary" data-edit="${u.id}">정보·연결 수정</button> <button class="btn secondary" data-reset="${u.id}">비밀번호 초기화</button> <button class="btn danger" data-delete="${u.id}">계정 삭제(접속중단)</button></td></tr>`).join('')}</table></div></div>`;
  function form(u={}){ctx.openModal(`<h3>${u.id?'기사 수정':'신규 기사 등록'}</h3><label>로그인 ID<input id="uLogin" value="${e(u.login_id||'')}" ${u.id?'disabled':''}></label>${u.id?'':'<label>초기 비밀번호 (6자 이상)<input id="uPw" type="password"></label>'}<label>공단 기사명 (B 등 표식 포함)<input id="uName" value="${e(u.etas_name||u.display_name||'')}"></label><label>재직 상태<select id="uState">${['재직','휴직','퇴사'].map(s=>`<option ${s===u.employment?'selected':''}>${s}</option>`).join('')}</select></label><label>적용일<input type="date" id="uDate" value="${e(u.effective_date||new Date().toLocaleDateString('sv-SE'))}"></label><label><input type="checkbox" id="uActive" ${u.active!==false?'checked':''}>접속 허용</label><button id="uSave" class="btn primary">저장</button>`);$('#uSave').onclick=run(async()=>{await api('user_save',{id:u.id||null,login_id:$('#uLogin').value,password:$('#uPw')?.value,etas_name:$('#uName').value,employment:$('#uState').value,effective_date:$('#uDate').value,active:$('#uActive').checked});ctx.closeModal();await render('drivers',ctx);});}
  $('#newDriver').onclick=()=>form();
  $('#linkAll').onclick=run(async()=>{const n=users.filter(u=>!u.etas_name).length;if(!n){ctx.toast('모든 기사가 이미 연결되어 있습니다.');return;}
   if(!confirm(`공단 이름이 연결되지 않은 기사 ${n}명을 계정 이름과 같은 공단 이름으로 연결합니다.\n이미 연결된 기사는 바꾸지 않습니다. 계속할까요?`))return;
   const r=await api('link_all');
   const list=(a)=>a.length?`<p>${a.map(x=>e(x)).join(', ')}</p>`:'<p>없음</p>';
   ctx.openModal(`<h3>전체 연결 결과</h3><p>새로 연결 <b>${r.linked}</b>명 · 이미 연결 ${r.already}명</p><h4>같은 이름이 있어 연결하지 못함 (${r.conflicts.length}명)</h4>${list(r.conflicts)}<h4>이름이 비어 있어 연결하지 못함 (${r.empty.length}명)</h4>${list(r.empty)}<p class="small">연결하지 못한 기사는 기사 계정 화면에서 '정보·연결 수정'으로 직접 연결하세요.</p>`);
   await render('drivers',ctx);});document.querySelectorAll('[data-edit]').forEach(b=>b.onclick=()=>form(users.find(u=>u.id===b.dataset.edit)));
  document.querySelectorAll('[data-delete]').forEach(b=>b.onclick=run(async()=>{if(confirm('로그인을 차단하고 기존 세션을 종료합니다. 과거 자료는 보존합니다. 진행할까요?')){await api('user_delete',{id:b.dataset.delete});await render('drivers',ctx);}}));
  document.querySelectorAll('[data-reset]').forEach(b=>b.onclick=run(async()=>{if(confirm('기존 방식대로 초기 비밀번호 1111로 초기화할까요?')){await ctx.rpc('admin_reset_password',{p_token:ctx.token(),p_user_id:b.dataset.reset});ctx.toast('초기화 완료. 첫 로그인 시 변경해야 합니다.');}}));
 }
 async function feedback(){
  $('#page').innerHTML=`<div class="card"><h3>${admin()?'기사별 피드백 대화창':'피드백 대화창'}</h3>${admin()?'':'<p class="muted">관리자와 주고받는 피드백입니다.</p>'}${admin()?`<label>기사<select id="msgUser"><option value="">선택</option>${opts()}</select></label>`:''}<div id="msgBody"></div></div>`;
  const load=async()=>{const id=admin()?$('#msgUser').value:ctx.state.session.user_id;if(!id)return;const messages=await api('messages',{user_id:id});$('#msgBody').innerHTML=`<div>${messages.map(m=>`<article class="card"><b>${e(m.author_name)} · ${e(m.kind)} ${m.internal?'[관리자 내부]':''}</b><small> ${e(new Date(m.created_at).toLocaleString('ko-KR'))}</small><p style="white-space:pre-wrap">${e(m.body)}</p></article>`).join('')||'<p>등록된 대화가 없습니다.</p>'}</div><label>관련 리포트<select id="msgReport"><option value="">일반 대화</option>${rows.filter(r=>r.user_id===id).map(r=>`<option value="${r.id}">${e(monthLabel(r.month))}</option>`).join('')}</select></label>${admin()?'<label>분류<select id="msgKind"><option>피드백</option><option>민원</option><option>사고</option><option>지도</option></select></label><label><input type="checkbox" id="msgInternal">관리자 내부 메모 (기사에게 숨김)</label>':''}<textarea id="msgText" maxlength="5000" rows="4" placeholder="${admin()?'피드백 내용을 입력하세요':'관리자에게 전할 내용을 입력하세요'}"></textarea><button id="msgSend" class="btn primary">${admin()?'기록 저장':'보내기'}</button>`;$('#msgSend').onclick=run(async()=>{await api('message_add',{user_id:id,report_id:$('#msgReport').value||null,body:$('#msgText').value,internal:$('#msgInternal')?.checked||false,kind:$('#msgKind')?.value||'피드백'});await load();});};if(admin())$('#msgUser').onchange=run(load);else await load();
 }
 return {render};
})();
