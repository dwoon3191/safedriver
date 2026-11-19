/* Dispatch (배차): file merge + validation (core), admin upload/view, driver "today" screen. */
(function(root){
 'use strict';
 /* ---------- core: pure functions (also run by node tests) ---------- */
 const core=(()=>{
  const nfc=x=>String(x??'').normalize('NFC').trim();
  function parseCsv(text){
   text=String(text||'').replace(/^﻿/,'');
   const rows=[];let row=[],cell='',q=false;
   for(let i=0;i<text.length;i++){
    const c=text[i];
    if(q){if(c==='"'){if(text[i+1]==='"'){cell+='"';i++;}else q=false;}else cell+=c;}
    else if(c==='"')q=true;
    else if(c===','){row.push(cell);cell='';}
    else if(c==='\n'||c==='\r'){if(c==='\r'&&text[i+1]==='\n')i++;row.push(cell);cell='';rows.push(row);row=[];}
    else cell+=c;
   }
   if(cell!==''||row.length){row.push(cell);rows.push(row);}
   return rows;
  }
  function dateText(v,csv){
   let s;
   if(v instanceof Date&&!isNaN(v)){s=new Date(v.getTime()+9*3600e3).toISOString().slice(0,10);}
   else if(typeof v==='number'&&v>30000&&v<80000){s=new Date(Date.UTC(1899,11,30)+Math.round(v)*864e5).toISOString().slice(0,10);}
   else{
    s=nfc(v);
    if(/^\d{8}$/.test(s))s=`${s.slice(0,4)}-${s.slice(4,6)}-${s.slice(6,8)}`;
    else if(/^\d{4}[-./]\d{1,2}[-./]\d{1,2}$/.test(s)){const [y,m,d]=s.split(/[-./]/);s=`${y}-${m.padStart(2,'0')}-${d.padStart(2,'0')}`;}
    else throw new Error(`날짜 형식 확인 필요 (${s||'빈 칸'})`);
   }
   const t=new Date(s+'T00:00:00Z');
   if(isNaN(t)||t.toISOString().slice(0,10)!==s)throw new Error(`존재하지 않는 날짜입니다 (${s})`);
   return s;
  }
  function routeText(v,allowEmpty){
   if(v instanceof Date)throw new Error('노선이 날짜로 바뀌었습니다. 파일을 엑셀에서 저장하지 말고 원본 그대로 올리세요.');
   if(typeof v==='number'){
    if(Number.isInteger(v)&&v>=1&&v<=9999)return String(v);
    throw new Error(`노선이 숫자·날짜로 바뀌었습니다 (${v}). 원본 파일을 그대로 올리세요.`);
   }
   const s=nfc(v);
   if(!s){if(allowEmpty)return null;throw new Error('노선이 비어 있습니다');}
   if(/^\d{1,2}월-\d{1,2}$/.test(s)||/^\d{1,2}-\d{1,2}월$/.test(s)||/^\d{4}[-./]\d{1,2}[-./]\d{1,2}/.test(s)||/^[A-Za-z]{3}-\d{1,2}$/.test(s))
    throw new Error(`노선이 날짜처럼 바뀌었습니다 (${s}). 원본 파일을 엑셀에서 저장하지 말고 그대로 올리세요.`);
   if(s.length>12||!/^[0-9A-Za-z가-힣]+(-[0-9A-Za-z가-힣]+)?$/.test(s))throw new Error(`노선 표기 확인 필요 (${s})`);
   return s;
  }
  function seqText(v,allowEmpty){
   const s=typeof v==='number'?(Number.isInteger(v)?String(v):'x'):nfc(v);
   if(!s&&allowEmpty)return null;
   if(!/^\d{1,3}$/.test(s)||Number(s)<1)throw new Error(`운행순번 확인 필요 (${s||'빈 칸'})`);
   return String(Number(s));
  }
  function timeText(v){
   if(v==null||nfc(v)==='')return null;
   if(typeof v==='number'||v instanceof Date)throw new Error('시각이 숫자·날짜로 바뀌었습니다. 원본 파일을 그대로 올리세요.');
   const s=nfc(v);
   if(!/^([01]\d|2[0-3])[0-5]\d$/.test(s))throw new Error(`시각은 4자리(예: 0513)여야 합니다 (${s})`);
   return s;
  }
  const carText=v=>{const s=nfc(v);if(!s||s.length>20)throw new Error('차량번호 확인 필요');return s;};
  const nameText=v=>{const s=nfc(v);return s?s:null;};

  const CSV_COLS={date:'일자',route:'노선번호',seq:'운행순번',am_time:'오전출발시간',pm_time:'오후출발시간',car:'차량번호'};
  const XLS_COLS={date:'운행일자',car:'차량번호',route:'노선명',seq:'운행순위',support_route:'지원노선명',support_seq:'지원운행순위',am_name:'오전승무원명',pm_name:'오후승무원명'};
  function headerMap(header,cols){
   const idx={};const names=header.map(nfc);
   for(const k of Object.keys(cols)){idx[k]=names.indexOf(cols[k]);}
   const missing=Object.keys(cols).filter(k=>idx[k]<0&&!(k==='support_route'||k==='support_seq')).map(k=>cols[k]);
   return {idx,missing};
  }
  function detect(rows){
   const h=(rows[0]||[]).map(nfc);
   if(h.includes('노선번호')&&h.includes('오전출발시간'))return 'csv';
   if(h.includes('오전승무원명')&&h.includes('오후승무원명'))return 'xls';
   return '';
  }
  function records(kind,rows,fileName){
   const cols=kind==='csv'?CSV_COLS:XLS_COLS;
   const out={records:[],errors:[]};
   const {idx,missing}=headerMap(rows[0]||[],cols);
   if(missing.length){out.errors.push(`${fileName}: 필요한 열이 없습니다 (${missing.join(', ')})`);return out;}
   for(let i=1;i<rows.length;i++){
    const r=rows[i];
    if(!r||r.every(x=>nfc(x)===''))continue;
    const where=`${fileName} ${i+1}행`;
    try{
     const rec={line:where,date:dateText(r[idx.date],kind==='csv'),route:routeText(r[idx.route]),seq:seqText(r[idx.seq]),car:carText(r[idx.car])};
     if(kind==='csv'){rec.am_time=timeText(r[idx.am_time]);rec.pm_time=timeText(r[idx.pm_time]);}
     else{
      rec.am_name=nameText(r[idx.am_name]);rec.pm_name=nameText(r[idx.pm_name]);
      rec.support_route=idx.support_route>=0?routeText(r[idx.support_route],true):null;
      rec.support_seq=idx.support_seq>=0?seqText(r[idx.support_seq],true):null;
     }
     out.records.push(rec);
    }catch(err){out.errors.push(`${where}: ${err.message}`);}
   }
   return out;
  }
  const sameRec=(a,b)=>JSON.stringify({...a,line:0})===JSON.stringify({...b,line:0});

  function merge(csvRecs,xlsRecs){
   const days=new Map();
   const day=d=>{if(!days.has(d))days.set(d,{date:d,rows:[],errors:[],warnings:[],csv:0,xls:0});return days.get(d);};
   const maps={CSV:new Map(),XLS:new Map()};const bad=new Set();const order=new Map();
   function add(kind,rec){
    const k=`${rec.date}|${rec.route}|${rec.seq}`;const d=day(rec.date);const map=maps[kind];const prev=map.get(k);
    if(prev){
     if(sameRec(prev,rec)){d.warnings.push(`${kind}: 같은 줄이 중복되어 하나만 사용했습니다 (${rec.route}번 ${rec.seq}순번)`);return;}
     d.errors.push(`${kind}: 같은 노선·순번이 서로 다른 내용으로 두 번 있습니다 (${rec.route}번 ${rec.seq}순번)`);bad.add(k);return;
    }
    map.set(k,rec);d[kind==='CSV'?'csv':'xls']++;
    if(kind==='CSV'&&!order.has(k))order.set(k,order.size);
   }
   csvRecs.forEach(r=>add('CSV',r));xlsRecs.forEach(r=>add('XLS',r));
   const keys=new Set([...maps.CSV.keys(),...maps.XLS.keys()]);
   for(const k of keys){
    if(bad.has(k))continue;
    const c=maps.CSV.get(k),x=maps.XLS.get(k);const date=k.split('|')[0];const d=day(date);
    if(!c||!x){const rec=c||x;d.errors.push(`${c?'CSV에만':'XLS에만'} 있는 줄: ${rec.route}번 ${rec.seq}순번 (${rec.line})`);continue;}
    if(c.car!==x.car){d.errors.push(`차량번호 불일치: ${c.route}번 ${c.seq}순번 — CSV ${c.car} / XLS ${x.car}`);continue;}
    d.rows.push({route:c.route,seq:Number(c.seq),car:c.car,am_name:x.am_name,am_time:c.am_time,pm_name:x.pm_name,pm_time:c.pm_time,
     support_route:x.support_route||null,support_seq:x.support_seq||null,ord:order.get(k)});
   }
   const out=[...days.values()].sort((a,b)=>a.date.localeCompare(b.date));
   for(const d of out){
    d.rows.sort((a,b)=>a.ord-b.ord||a.route.localeCompare(b.route)||a.seq-b.seq);
    d.rows.forEach((r,i)=>{r.ord=i;});
    // one person must appear only once per day (오전·오후 포함)
    const who=new Map();
    for(const r of d.rows)for(const [sh,n,t] of [['오전',r.am_name,r.am_time],['오후',r.pm_name,r.pm_time]]){
     if(!n)continue;if(!who.has(n))who.set(n,[]);who.get(n).push(`${r.route}번 ${r.seq}순번 ${sh}반`);
    }
    for(const [n,w] of who)if(w.length>1)d.errors.push(`중복 배차: ${n} — ${w.join(' / ')}`);
    const blankAm=d.rows.filter(r=>!r.am_name).length,blankPm=d.rows.filter(r=>!r.pm_name).length;
    if(blankAm)d.warnings.push(`오전 승무원이 비어 있는 줄 ${blankAm}개`);
    if(blankPm)d.warnings.push(`오후 승무원이 비어 있는 줄 ${blankPm}개`);
    const noTime=d.rows.filter(r=>(r.am_name&&!r.am_time)||(r.pm_name&&!r.pm_time)).length;
    if(noTime)d.warnings.push(`승무원은 있는데 출발시각이 비어 있는 줄 ${noTime}개`);
    const rev=d.rows.filter(r=>r.am_time&&r.pm_time&&r.am_time>=r.pm_time).length;
    if(rev)d.warnings.push(`오전 출발시각이 오후 출발시각보다 늦거나 같은 줄 ${rev}개 — 값을 확인하세요`);
    const byRoute=new Map();for(const r of d.rows){if(!byRoute.has(r.route))byRoute.set(r.route,[]);byRoute.get(r.route).push(r.seq);}
    const gaps=[];for(const [rt,s] of byRoute){const set=new Set(s);const miss=[];for(let i=1;i<=Math.max(...s);i++)if(!set.has(i))miss.push(i);if(miss.length)gaps.push(`${rt}번 ${miss.join('·')}`);}
    if(gaps.length)d.warnings.push(`빠진 운행순번 (운휴인지 누락인지 파일만으로는 알 수 없습니다): ${gaps.join(', ')}`);
    const sup=d.rows.filter(r=>r.support_route).length;
    if(sup)d.warnings.push(`지원노선 값이 있는 줄 ${sup}개 (그대로 저장됩니다)`);
    d.unmatchedCheck=names=>{const set=new Set(names.map(nfc));const s=new Set();for(const r of d.rows)for(const n of [r.am_name,r.pm_name])if(n&&!set.has(n))s.add(n);return [...s];};
   }
   return out;
  }
  const fmtTime=t=>{if(!t||!/^\d{4}$/.test(t))return '';const h=Number(t.slice(0,2)),m=t.slice(2);const ap=h<12?'오전':'오후';const hh=h%12===0?12:h%12;return `${ap} ${hh}:${m}`;};
  const WD=['일','월','화','수','목','금','토'];
  const dateLabel=d=>{const t=new Date(d+'T00:00:00Z');return {md:`${t.getUTCMonth()+1}/${t.getUTCDate()}`,long:`${t.getUTCMonth()+1}월 ${t.getUTCDate()}일 (${WD[t.getUTCDay()]})`,wd:WD[t.getUTCDay()]};};
  const seoulDate=(offset=0,now=new Date())=>new Date(now.getTime()+9*3600e3+offset*864e5).toISOString().slice(0,10);
  const carShort=c=>{const m=String(c||'').match(/(\d{4})$/);return m?m[1]:String(c||'');};
  return {parseCsv,detect,records,merge,fmtTime,dateLabel,seoulDate,carShort,routeText,timeText,nfc};
 })();
 root.DispatchCore=core;
 if(typeof module!=='undefined'&&module.exports)module.exports=core;
 if(typeof document==='undefined')return;

 /* ---------- UI ---------- */
 let ctx,epoch=0;
 const e=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const $=s=>document.querySelector(s);
 const api=async(action,data={})=>{const r=await fetch('/.netlify/functions/monthly',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:ctx.token(),action,data})});const v=await r.json();if(!r.ok)throw Error(v.error||'요청 실패');return v;};
 const run=fn=>async ev=>{const b=ev?.currentTarget;if(b)b.disabled=true;try{await fn(ev);}catch(x){ctx.toast(x.message,true);}finally{if(b)b.disabled=false;}};
 async function render(page,c){ctx=c;++epoch;
  if(page==='dpadmin'){if(ctx.state.session.role!=='admin')throw Error('관리자 전용 화면입니다.');return adminPage();}
  return driverPage();
 }

 /* ----- driver: 오늘 근무 ----- */
 async function driverPage(){
  const my=epoch;
  const dates=[0,1,2].map(o=>core.seoulDate(o));
  $('#page').innerHTML='<div class="wk-wrap"><p class="wk-note">불러오는 중…</p></div>';
  const res=await api('dp_mine',{dates});
  if(my!==epoch)return;
  let sel=0;
  const tabLabel=(d,i)=>`${['오늘','내일','모레'][i]}<small>${core.dateLabel(d).md}(${core.dateLabel(d).wd})</small>`;
  function draw(){
   const day=res.days.find(x=>x.date===dates[sel])||{status:'unregistered',date:dates[sel]};
   const L=core.dateLabel(dates[sel]);
   let body='';
   if(day.status==='unregistered')body=`<section class="wk-card wk-off"><div class="wk-shift">배차 미등록</div><p class="wk-text">${e(L.long)} 배차표가 아직 등록되지 않았습니다.<br>등록되면 이 화면에 표시됩니다.</p></section>`;
   else if(day.status==='off')body=`<section class="wk-card wk-off"><div class="wk-shift">휴무</div><p class="wk-text">${e(L.long)}은 휴무입니다.</p></section>`;
   else body=day.items.map((it,k)=>{
    const am=it.shift==='am';const time=am?it.am_time:it.pm_time;
    const other=am?{label:'오후반',name:it.pm_name,t:it.pm_time}:{label:'오전반',name:it.am_name,t:it.am_time};
    return `<section class="wk-card ${am?'wk-am':'wk-pm'}"><div class="wk-shift">${am?'오전반':'오후반'}</div>
      <div class="wk-route"><b>${e(it.route)}</b>번 노선</div>
      <div class="wk-line">배차순번 <b>${e(it.seq)}</b></div>
      <div class="wk-line">차량 <b>${e(core.carShort(it.car))}</b> <small>${e(it.car)}</small></div>
      <div class="wk-time">${e(core.fmtTime(time)||'시각 미정')} 출발</div>
      ${it.support_route?`<div class="wk-line">지원노선 <b>${e(it.support_route)}</b>${it.support_seq?` · 순번 ${e(it.support_seq)}`:''}</div>`:''}
     </section>
     <div class="wk-partner">같은 차 ${other.label}: ${other.name?`<b>${e(other.name)}</b>${other.t?` · ${e(core.fmtTime(other.t))} 출발`:''}`:'배정 없음'}</div>
     <button class="wk-more" data-more="${k}">${e(it.route)}번 노선 전체 보기 ▾</button>
     <div class="wk-routetbl hidden" id="wkr${k}">${routeTable(it)}</div>`;}).join('');
   $('#page').innerHTML=`<div class="wk-wrap"><div class="wk-tabs">${dates.map((d,i)=>`<button class="wk-tab ${i===sel?'on':''}" data-i="${i}">${tabLabel(d,i)}</button>`).join('')}</div><div class="wk-date">${e(L.long)}</div>${body}</div>`;
   document.querySelectorAll('.wk-tab').forEach(b=>b.onclick=()=>{sel=Number(b.dataset.i);draw();});
   document.querySelectorAll('[data-more]').forEach(b=>b.onclick=()=>{const t=$('#wkr'+b.dataset.more);t.classList.toggle('hidden');b.textContent=b.textContent.replace(/[▾▴]$/,t.classList.contains('hidden')?'▾':'▴');});
  }
  function routeTable(it){
   const mine=n=>n&&n===res.name;
   const cell=(n,t)=>n?`${e(n)}<br><small>${e(core.fmtTime(t))}</small>`:'<span class="muted">-</span>';
   return `<table class="wk-table"><thead><tr><th>순번</th><th>차량</th><th>오전반</th><th>오후반</th></tr></thead><tbody>${it.route_rows.map(r=>`<tr><td>${e(r.seq)}</td><td>${e(core.carShort(r.car))}</td><td class="${mine(r.am_name)?'me':''}">${cell(r.am_name,r.am_time)}</td><td class="${mine(r.pm_name)?'me':''}">${cell(r.pm_name,r.pm_time)}</td></tr>`).join('')}</tbody></table>`;
  }
  draw();
 }

 /* ----- admin: 업로드 + 조회 ----- */
 function adminPage(){
  const my=epoch;let merged=[],readErrors=[],users=[],existing=new Map();
  $('#page').innerHTML=`<div class="card"><h3>① 배차 파일 올리기</h3>
   <p>배차시간표 <b>CSV</b>와 승무원표 <b>XLS</b>를 함께 선택하세요. 3~4일치를 한꺼번에 선택해도 됩니다. 두 파일을 <b>엑셀에서 열어 저장하지 말고 내려받은 원본 그대로</b> 올리세요(노선 73-1 등이 날짜로 바뀝니다).</p>
   <input type="file" id="dpFiles" multiple accept=".csv,.xls,.xlsx">
   <div class="toolbar"><button id="dpScan" class="btn secondary">파일 검사</button><button id="dpSave" class="btn primary" disabled>체크한 날짜 저장</button></div>
   <div id="dpPreview"></div></div>
   <div class="card"><h3>② 날짜별 배차일지</h3><div class="toolbar"><label>날짜<select id="dpDate"></select></label><label>검색<input id="dpSearch" placeholder="기사 이름·노선·차량"></label></div><div id="dpSummary"></div><div class="table-wrap" id="dpTable"></div><div id="dpOff"></div></div>`;
  async function loadDays(){
   const days=await api('dp_days');if(my!==epoch)return;
   existing=new Map(days.map(d=>[d.date,d]));
   $('#dpDate').innerHTML=days.length?days.map(d=>`<option value="${d.date}">${core.dateLabel(d.date).long} · ${d.rows}줄</option>`).join(''):'<option value="">등록된 날짜 없음</option>';
   if(days.length)await loadDay();else{$('#dpTable').innerHTML='<p>등록된 배차가 없습니다.</p>';$('#dpSummary').textContent='';$('#dpOff').innerHTML='';}
  }
  let dayRows=[],off=[];
  async function loadDay(){
   const d=$('#dpDate').value;if(!d)return;
   const r=await api('dp_day',{date:d});dayRows=r.rows||[];off=r.off||[];drawDay();
  }
  function drawDay(){
   const q=core.nfc($('#dpSearch').value).toLowerCase();
   const list=dayRows.filter(r=>!q||[r.route,r.car,r.am_name,r.pm_name].some(x=>String(x||'').toLowerCase().includes(q)));
   const am=new Set(dayRows.map(r=>r.am_name).filter(Boolean)).size,pm=new Set(dayRows.map(r=>r.pm_name).filter(Boolean)).size;
   $('#dpSummary').innerHTML=`<p>운행 ${dayRows.length}줄 · 오전반 <b>${am}</b>명 · 오후반 <b>${pm}</b>명 · 휴무자 <b>${off.length}</b>명</p>`;
   $('#dpTable').innerHTML=`<table><thead><tr><th>연번</th><th>차량</th><th>노선</th><th>순번</th><th>오전반</th><th>출발</th><th>오후반</th><th>출발</th></tr></thead><tbody>${list.map((r,i)=>`<tr><td>${i+1}</td><td>${e(core.carShort(r.car))}</td><td>${e(r.route)}</td><td>${e(r.seq)}</td><td>${e(r.am_name||'')}</td><td>${e(core.fmtTime(r.am_time))}</td><td>${e(r.pm_name||'')}</td><td>${e(core.fmtTime(r.pm_time))}</td></tr>`).join('')||'<tr><td colspan="8">조건에 맞는 줄이 없습니다.</td></tr>'}</tbody></table>`;
   $('#dpOff').innerHTML=`<h4>휴무자 (${off.length}명)</h4><p>${off.map(e).join(', ')||'없음'}</p><p class="small muted">휴무자는 앱에 등록된 접속 허용 기사 중 이날 배차에 이름이 없는 사람입니다. 휴직·신규 입사 여부는 구분하지 않습니다.</p>`;
  }
  $('#dpDate').onchange=run(loadDay);$('#dpSearch').oninput=drawDay;

  function drawPreview(){
   if(!merged.length&&!readErrors.length){$('#dpPreview').innerHTML='';$('#dpSave').disabled=true;return;}
   const nameList=users.map(u=>u.etas_name||u.display_name);
   $('#dpPreview').innerHTML=`${readErrors.length?`<div class="notice warn"><b>읽지 못한 파일/줄 (${readErrors.length})</b><br>${readErrors.slice(0,30).map(e).join('<br>')}${readErrors.length>30?'<br>…':''}</div>`:''}
   <div class="table-wrap"><table><thead><tr><th>저장</th><th>날짜</th><th>CSV</th><th>XLS</th><th>합친 줄</th><th>오류</th><th>경고</th><th>앱에 없는 이름</th><th>비고</th></tr></thead><tbody>${merged.map((d,i)=>{
    const um=d.unmatchedCheck(nameList);const bad=d.errors.length>0;
    return `<tr><td><input type="checkbox" class="dpPick" data-i="${i}" ${bad?'disabled':'checked'}></td><td>${e(core.dateLabel(d.date).long)}</td><td>${d.csv}</td><td>${d.xls}</td><td>${d.rows.length}</td><td class="${bad?'bad':''}">${d.errors.length}</td><td>${d.warnings.length}</td><td>${um.length}</td><td>${bad?'오류가 있어 저장 불가':existing.has(d.date)?'<b>이미 등록됨 — 덮어씁니다</b>':'새로 저장'}</td></tr>
    ${d.errors.length||d.warnings.length||um.length?`<tr><td></td><td colspan="8"><details ${bad?'open':''}><summary>자세히 보기</summary>${d.errors.length?`<p class="bad"><b>오류</b><br>${d.errors.slice(0,40).map(e).join('<br>')}${d.errors.length>40?'<br>…':''}</p>`:''}${d.warnings.length?`<p><b>경고</b><br>${d.warnings.map(e).join('<br>')}</p>`:''}${um.length?`<p><b>앱 기사 계정과 이름이 맞지 않는 사람 (${um.length}명, 저장은 가능)</b><br>${um.map(e).join(', ')}</p>`:''}</details></td></tr>`:''}`;}).join('')}</tbody></table></div>`;
   const upd=()=>{$('#dpSave').disabled=!document.querySelector('.dpPick:checked');};
   document.querySelectorAll('.dpPick').forEach(x=>x.onchange=upd);upd();
  }
  async function readFile(file,csvRecs,xlsRecs){
   const ext=file.name.split('.').pop().toLowerCase();
   try{
    const buf=await file.arrayBuffer();let rows;
    if(ext==='csv'){
     let text=new TextDecoder('euc-kr').decode(buf);
     if(!core.detect(core.parseCsv(text)))text=new TextDecoder('utf-8').decode(buf);
     rows=core.parseCsv(text);
    }else{
     if(!window.XLSX)throw Error('엑셀 읽기 도구를 불러오지 못했습니다. 인터넷 연결을 확인하세요.');
     const wb=XLSX.read(buf,{type:'array',cellDates:true,raw:true});
     rows=XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]],{header:1,raw:true,defval:''});
    }
    const kind=core.detect(rows);
    if(!kind){readErrors.push(`${file.name}: 배차시간표(CSV)도 승무원표(XLS)도 아닙니다. 첫 줄의 열 이름을 확인하세요.`);return;}
    const r=core.records(kind,rows,file.name);readErrors.push(...r.errors);(kind==='csv'?csvRecs:xlsRecs).push(...r.records);
   }catch(err){readErrors.push(`${file.name}: ${err.message}`);}
  }
  $('#dpScan').onclick=run(async()=>{
   const files=[...$('#dpFiles').files];if(!files.length)throw Error('파일을 선택하세요.');
   merged=[];readErrors=[];const csvRecs=[],xlsRecs=[];
   for(const f of files)await readFile(f,csvRecs,xlsRecs);
   if(!csvRecs.length||!xlsRecs.length)readErrors.push('CSV(배차시간표)와 XLS(승무원표)를 모두 선택해야 합니다.');
   else merged=core.merge(csvRecs,xlsRecs);
   try{users=await api('users');}catch{users=[];}
   try{const days=await api('dp_days');existing=new Map(days.map(d=>[d.date,d]));}catch{}
   drawPreview();
  });
  $('#dpSave').onclick=run(async()=>{
   const picked=[...document.querySelectorAll('.dpPick:checked')].map(x=>merged[Number(x.dataset.i)]).filter(d=>d&&!d.errors.length);
   if(!picked.length)throw Error('저장할 날짜를 선택하세요.');
   const over=picked.filter(d=>existing.has(d.date));
   if(over.length&&!confirm(`이미 등록된 ${over.map(d=>core.dateLabel(d.date).md).join(', ')} 배차를 새 파일로 덮어씁니다. 계속할까요?`))return;
   const source=[...$('#dpFiles').files].map(f=>f.name).join(', ');
   let saved=0;
   for(let i=0;i<picked.length;i+=7){
    const part=picked.slice(i,i+7);
    const r=await api('dp_upload',{days:part.map(d=>({date:d.date,source,rows:d.rows}))});saved+=r.saved.length;
   }
   ctx.toast(`${saved}일치 배차를 저장했습니다.`);
   merged=[];readErrors=[];drawPreview();await loadDays();
  });
  loadDays().catch(x=>ctx.toast(x.message,true));
 }
 root.Dispatch={render};
})(typeof window!=='undefined'?window:globalThis);
