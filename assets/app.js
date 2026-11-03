(() => {
  'use strict';
  const $ = s => document.querySelector(s);
  const $$ = s => [...document.querySelectorAll(s)];
  const state = { cfg:null, session:null, page:'dashboard', cache:{} };
  const fmtDate = d => { const x=new Date(d); if(Number.isNaN(x.getTime())) return d||''; return x.toLocaleDateString('ko-KR'); };
  const fmtDT = d => { const x=new Date(d); if(Number.isNaN(x.getTime())) return d||''; return x.toLocaleString('ko-KR',{hour12:false}); };
  const esc = v => String(v??'').replace(/[&<>'"]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[m]));
  const n = v => Number(v||0);
  function toast(msg,error=false){ const el=$('#toast'); el.textContent=msg; el.className='toast show'+(error?' error':''); setTimeout(()=>el.className='toast',2800); }
  function show(id){ ['setupView','loginView','appView'].forEach(x=>$('#'+x).classList.add('hidden')); $('#'+id).classList.remove('hidden'); }
  function openModal(html){ $('#modalBody').innerHTML=html; $('#modal').classList.remove('hidden'); }
  function closeModal(){ $('#modal').classList.add('hidden'); }
  $('#modalClose').onclick=closeModal;
  $('#modal').addEventListener('click',e=>{ if(e.target.id==='modal') closeModal(); });

  function loadCfg(){
    const built = window.DAEWOON_CONFIG||{};
    const saved = JSON.parse(localStorage.getItem('daewoon_supabase')||'{}');
    state.cfg = { url:(saved.url||built.SUPABASE_URL||'').replace(/\/$/,''), key:saved.key||built.SUPABASE_ANON_KEY||'' };
    return state.cfg.url && state.cfg.key;
  }
  function saveCfg(url,key){ localStorage.setItem('daewoon_supabase',JSON.stringify({url:url.replace(/\/$/,''),key})); loadCfg(); }
  async function rpc(fn, body={}){
    if(!state.cfg?.url) throw new Error('Supabase 연결정보가 없습니다.');
    const r = await fetch(`${state.cfg.url}/rest/v1/rpc/${fn}`,{method:'POST',headers:{'Content-Type':'application/json','apikey':state.cfg.key,'Authorization':`Bearer ${state.cfg.key}`},body:JSON.stringify(body)});
    const text=await r.text(); let data; try{data=text?JSON.parse(text):null}catch{data=text}
    if(!r.ok){ let m=data?.message||data?.hint||text||`HTTP ${r.status}`; throw new Error(m); }
    return data;
  }
  function token(){ return state.session?.token||''; }
  function saveSession(s){ state.session=s; localStorage.setItem('daewoon_session',JSON.stringify(s)); }
  function clearSession(){ state.session=null; localStorage.removeItem('daewoon_session'); }

  async function init(){
    loadCfg();
    if(!state.cfg.url || !state.cfg.key){ show('setupView'); return; }
    const saved=JSON.parse(localStorage.getItem('daewoon_session')||'null');
    if(saved?.token){
      try{ const me=await rpc('app_me',{p_token:saved.token}); saveSession({...saved,...me}); return enterApp(); }catch{ clearSession(); }
    }
    show('loginView');
  }

  $('#saveSetupBtn').onclick=async()=>{
    const u=$('#setupUrl').value.trim(), k=$('#setupKey').value.trim();
    if(!u||!k) return toast('URL과 key를 모두 입력하세요.',true);
    saveCfg(u,k); toast('저장했습니다.'); show('loginView');
  };
  $('#openSetupBtn').onclick=()=>{ $('#setupUrl').value=state.cfg?.url||''; $('#setupKey').value=state.cfg?.key||''; show('setupView'); };
  $('#loginBtn').onclick=login;
  $('#loginPw').addEventListener('keydown',e=>{if(e.key==='Enter')login();});
  async function login(){
    try{
      const id=$('#loginId').value.trim(), pw=$('#loginPw').value;
      if(!id||!pw) return toast('아이디와 비밀번호를 입력하세요.',true);
      const s=await rpc('app_login',{p_login_id:id,p_password:pw}); saveSession(s); enterApp();
    }catch(e){ toast(e.message,true); }
  }
  $('#logoutBtn').onclick=async()=>{ try{ await rpc('app_logout',{p_token:token()}); }catch{} clearSession(); show('loginView'); };
  $('#menuBtn').onclick=()=>$('.sidebar').classList.toggle('open');

  function enterApp(){
    show('appView');
    $('#userBox').innerHTML=`<b>${esc(state.session.display_name)}</b><br><span>${state.session.role==='admin'?'관리자':'운전자'}</span>`;
    buildNav();
    if(state.session.must_change_password){ setTimeout(forcePasswordChange,150); }
    navigate('dashboard');
  }
  function buildNav(){
    const admin=[['dashboard','▦ 대시보드'],['dispatch','▤ 배차표 관리'],['etas','▧ eTAS 리포트'],['changes','⇄ 차량변경'],['drivers','♙ 기사 계정'],['acks','✓ 확인현황'],['audit','◷ 작업이력'],['settings','⚙ 설정/설치']];
    const driver=[['dashboard','▦ 나의 운행분석'],['history','▤ 운행이력'],['settings','⚙ 비밀번호/정보']];
    $('#nav').innerHTML=(state.session.role==='admin'?admin:driver).map(([id,t])=>`<button class="nav-btn" data-page="${id}">${t}</button>`).join('');
    $$('.nav-btn').forEach(b=>b.onclick=()=>{navigate(b.dataset.page);$('.sidebar').classList.remove('open');});
  }
  function navigate(p){ state.page=p; $$('.nav-btn').forEach(b=>b.classList.toggle('active',b.dataset.page===p)); const title={dashboard:state.session.role==='admin'?'운영 대시보드':'나의 안전운전 분석',dispatch:'배차표 관리',etas:'교통안전공단 eTAS 리포트',changes:'BIS 차량변경',drivers:'기사 계정',acks:'분석결과 확인현황',audit:'작업 이력',history:'나의 운행이력',settings:'설정'}[p]||p; $('#pageTitle').textContent=title; $('#pageSubtitle').textContent='대운교통 SafeDrive · CDT / BIS / eTAS 통합'; $('#topActions').innerHTML=''; renderPage(p).catch(e=>{ $('#page').innerHTML=`<div class="notice warn">${esc(e.message)}</div>`; toast(e.message,true); }); }
  async function renderPage(p){
    if(state.session.role==='admin'){
      if(p==='dashboard') return adminDashboard(); if(p==='dispatch') return dispatchPage(); if(p==='etas') return etasPage(); if(p==='changes') return changesPage(); if(p==='drivers') return driversPage(); if(p==='acks') return ackPage(); if(p==='audit') return auditPage(); if(p==='settings') return settingsPage();
    }else{
      if(p==='dashboard') return driverDashboard(); if(p==='history') return driverHistory(); if(p==='settings') return settingsPage();
    }
  }

  function forcePasswordChange(){
    openModal(`<h2>첫 로그인 비밀번호 변경</h2><p class="notice warn">초기 비밀번호 1111은 계속 사용할 수 없습니다.</p><div class="form-grid"><label>현재 비밀번호<input id="oldpw" type="password" value="1111"></label><label>새 비밀번호<input id="newpw" type="password" placeholder="6자 이상"></label><label class="span-2">새 비밀번호 확인<input id="newpw2" type="password"></label></div><button id="changePwBtn" class="btn primary full">비밀번호 변경</button>`);
    $('#modalClose').classList.add('hidden');
    $('#changePwBtn').onclick=async()=>{ const a=$('#newpw').value,b=$('#newpw2').value;if(a!==b)return toast('새 비밀번호가 일치하지 않습니다.',true); try{await rpc('app_change_password',{p_token:token(),p_old_password:$('#oldpw').value,p_new_password:a}); state.session.must_change_password=false;saveSession(state.session);$('#modalClose').classList.remove('hidden');closeModal();toast('비밀번호를 변경했습니다.');}catch(e){toast(e.message,true);} };
  }

  async function adminDashboard(){
    const today=new Date().toISOString().slice(0,10); const d=await rpc('admin_dashboard',{p_token:token(),p_service_date:today});
    $('#page').innerHTML=`<div class="grid cols-4"><div class="card metric"><span class="label">등록 기사</span><span class="value">${d.counts.drivers}</span></div><div class="card metric"><span class="label">오늘 배차</span><span class="value">${d.counts.dispatch}</span></div><div class="card metric warn"><span class="label">오늘 차량변경</span><span class="value">${d.counts.vehicle_changes}</span></div><div class="card metric bad"><span class="label">미확인 분석</span><span class="value">${d.counts.unacknowledged}</span></div></div>
    <div class="section-title"><h3>오늘 차량변경</h3><button class="btn secondary" onclick="window.appGo('changes')">전체보기</button></div>${tableChanges(d.changes)}
    <div class="section-title"><h3>오늘 CDT 후보 이벤트 요약</h3></div>${tableTaco(d.taco_daily)}
    <div class="section-title"><h3>최근 타코 수집</h3></div>${tableImports(d.recent_imports)}`;
  }
  window.appGo=navigate;
  function tableChanges(rows){ if(!rows?.length)return '<div class="card empty">차량변경 기록이 없습니다.</div>'; return `<div class="table-wrap"><table><thead><tr><th>시각</th><th>노선</th><th>순번</th><th>기사</th><th>기존차량</th><th>변경차량</th><th>신뢰도</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${fmtDT(r.detected_at)}</td><td>${esc(r.route_no)}</td><td>${r.run_order>0?r.run_order:'-'}</td><td>${esc(r.driver_name)}</td><td>${esc(r.old_vehicle)}</td><td><b>${esc(r.new_vehicle)}</b></td><td>${badge(r.confidence)}</td></tr>`).join('')}</tbody></table></div>`; }
  function tableTaco(rows){ if(!rows?.length)return '<div class="card empty">오늘 분석된 CDT 자료가 없습니다.</div>'; return `<div class="table-wrap"><table><thead><tr><th>기사</th><th>차량</th><th>노선</th><th>거리</th><th>최고속도</th><th>급출발</th><th>급가속</th><th>급감속</th><th>급정지</th><th>관리속도</th><th>품질</th></tr></thead><tbody>${rows.map(r=>`<tr><td><b>${esc(r.driver_name)}</b></td><td>${esc(r.vehicle_no)}</td><td>${esc(r.route_no)}</td><td>${n(r.distance_km).toFixed(1)}km</td><td>${n(r.max_speed)}</td><td>${r.rapid_start}</td><td>${r.rapid_accel}</td><td>${r.rapid_decel}</td><td>${r.rapid_stop}</td><td>${r.speed_watch}</td><td>${esc(r.data_quality)}</td></tr>`).join('')}</tbody></table></div>`; }
  function tableImports(rows){ if(!rows?.length)return '<div class="card empty">수집 이력이 없습니다.</div>';return `<div class="table-wrap"><table><thead><tr><th>수집시각</th><th>파일</th><th>차량</th><th>운행일</th><th>레코드</th><th>파서</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${fmtDT(r.imported_at)}</td><td>${esc(r.source_file)}</td><td>${esc(r.vehicle_no)}</td><td>${esc(r.service_date)}</td><td>${r.record_count}</td><td>${esc(r.parser_version)}</td></tr>`).join('')}</tbody></table></div>`; }
  function badge(v){ const x=String(v||''); const c=/high|양호|완료|확인/i.test(x)?'good':/low|위험|미확인/i.test(x)?'bad':'warn';return `<span class="badge ${c}">${esc(x)}</span>`; }

  async function dispatchPage(){
    const today=new Date().toISOString().slice(0,10); $('#page').innerHTML=`<div class="card"><h3>배차표 엑셀 업로드</h3><p class="notice">첨부 샘플의 두 형식을 자동 인식합니다. ① 차량별 근무시작/종료시간표 ② 노선·운행순위·오전/오후 승무원표. 두 파일을 순서와 관계없이 올리면 같은 날짜·차량·기사 기준으로 보완됩니다.</p><div class="dropzone" id="dispatchDrop"><input id="dispatchFile" type="file" accept=".xls,.xlsx,.csv" multiple><p>배차표 파일을 선택하거나 끌어놓으세요.</p></div><div id="dispatchPreview"></div></div><div class="section-title"><h3>등록된 배차</h3><div class="toolbar"><input id="dispatchDate" type="date" value="${today}"><button id="loadDispatch" class="btn secondary">조회</button></div></div><div id="dispatchList"></div>`;
    const input=$('#dispatchFile'); input.onchange=()=>handleDispatchFiles([...input.files]);
    const dz=$('#dispatchDrop'); ['dragenter','dragover'].forEach(e=>dz.addEventListener(e,x=>{x.preventDefault();dz.classList.add('drag')})); ['dragleave','drop'].forEach(e=>dz.addEventListener(e,x=>{x.preventDefault();dz.classList.remove('drag')})); dz.addEventListener('drop',e=>handleDispatchFiles([...e.dataTransfer.files]));
    $('#loadDispatch').onclick=loadDispatchList; loadDispatchList();
  }
  function mergeDispatchRows(rows){
    const m=new Map();
    for(const r of rows){
      const key=[r.service_date,r.vehicle_no,r.driver_name,r.shift_type].join('|');
      const a=m.get(key);
      if(!a){ m.set(key,{...r}); continue; }
      if(!a.shift_start && r.shift_start) a.shift_start=r.shift_start;
      if(!a.shift_end && r.shift_end) a.shift_end=r.shift_end;
      if((!a.route_no || a.route_no==='-1') && r.route_no) a.route_no=r.route_no;
      if((!a.run_order || a.run_order<1) && Number(r.run_order)>0) a.run_order=Number(r.run_order);
      if(!a.support_route_no && r.support_route_no) a.support_route_no=r.support_route_no;
      if((a.support_run_order===null || a.support_run_order===undefined) && Number(r.support_run_order)>0) a.support_run_order=Number(r.support_run_order);
      if(a.source_format!==r.source_format) a.source_format='MERGED';
    }
    return [...m.values()];
  }
  async function handleDispatchFiles(files){
    if(typeof XLSX==='undefined') return toast('SheetJS를 불러오지 못했습니다. 인터넷 연결을 확인하세요.',true);
    let all=[]; for(const f of files){ const rows=await readSheet(f); const norm=normalizeDispatch(rows,f.name); all.push(...norm); }
    if(!all.length) return toast('인식 가능한 배차 데이터가 없습니다.',true);
    const merged=mergeDispatchRows(all);
    const mergedMsg=all.length===merged.length?`${merged.length}건`:`원본 ${all.length}건 → 중복/보완 병합 ${merged.length}건`;
    $('#dispatchPreview').innerHTML=`<div class="notice">${files.length}개 파일에서 ${mergedMsg}을 저장 대상으로 인식했습니다.</div><div class="table-wrap"><table><thead><tr><th>일자</th><th>차량</th><th>기사</th><th>구분</th><th>노선</th><th>순번</th><th>시작</th><th>종료</th></tr></thead><tbody>${merged.slice(0,30).map(r=>`<tr><td>${r.service_date}</td><td>${esc(r.vehicle_no)}</td><td>${esc(r.driver_name)}</td><td>${r.shift_type}</td><td>${esc(r.route_no)}</td><td>${r.run_order||''}</td><td>${r.shift_start?fmtDT(r.shift_start):'-'}</td><td>${r.shift_end?fmtDT(r.shift_end):'-'}</td></tr>`).join('')}</tbody></table></div><button id="saveDispatch" class="btn primary" style="margin-top:12px">Supabase에 ${merged.length}건 저장</button>`;
    $('#saveDispatch').onclick=async()=>{
      const btn=$('#saveDispatch'); const source=files.map(f=>f.name).join(', '); const batchSize=100;
      let saved=0;
      try{
        btn.disabled=true;
        for(let i=0;i<merged.length;i+=batchSize){
          const part=merged.slice(i,i+batchSize);
          btn.textContent=`저장 중 ${Math.min(i+part.length,merged.length)}/${merged.length}`;
          const d=await rpc('admin_import_dispatch',{p_token:token(),p_rows:part,p_source_file:`${source} [${Math.floor(i/batchSize)+1}/${Math.ceil(merged.length/batchSize)}]`});
          saved+=Number(d?.rows||0);
        }
        toast(`${saved}건 저장했습니다.`);
        if(merged[0]?.service_date && $('#dispatchDate')) $('#dispatchDate').value=merged[0].service_date;
        btn.textContent=`저장 완료 ${saved}건`;
        await loadDispatchList();
      }catch(e){
        btn.disabled=false; btn.textContent=`다시 저장 (${saved}/${merged.length} 처리)`;
        toast(`${saved}건 처리 후 오류: ${e.message}`,true);
      }
    };
  }
  function excelTimeToHHMM(v){ if(v===null||v===undefined||v==='')return null; if(typeof v==='number'){ const min=Math.round((v%1)*1440); return `${String(Math.floor(min/60)%24).padStart(2,'0')}:${String(min%60).padStart(2,'0')}`; } const s=String(v).trim(); if(/^\d{1,2}:\d{2}/.test(s))return s.slice(0,5); return null; }
  function normalizeDate(v){ if(v===null||v===undefined||v==='')return null; const s=String(v).trim(); if(/^\d{8}$/.test(s))return `${s.slice(0,4)}-${s.slice(4,6)}-${s.slice(6,8)}`; if(/^\d{4}-\d{2}-\d{2}/.test(s))return s.slice(0,10); if(typeof v==='number'&&v>30000){ const d=XLSX.SSF.parse_date_code(v); return `${d.y}-${String(d.m).padStart(2,'0')}-${String(d.d).padStart(2,'0')}`; } return null; }
  function isoLocal(date,hm){ if(!date||!hm)return null; return `${date}T${hm}:00+09:00`; }
  function normalizeDispatch(rows,file){
    if(!rows.length)return[]; const hdr=rows[0].map(x=>String(x??'').trim()); const idx=x=>hdr.indexOf(x); const out=[];
    if(idx('차량번호')>=0 && idx('운전자이름')>=0 && idx('근무시작일자')>=0){
      for(const a of rows.slice(1)){ const date=normalizeDate(a[idx('근무시작일자')]), ed=normalizeDate(a[idx('근무종료일자')])||date, st=excelTimeToHHMM(a[idx('근무시작시간')]), et=excelTimeToHHMM(a[idx('근무종료시간')]); if(!date||!a[idx('차량번호')]||!a[idx('운전자이름')])continue; out.push({service_date:date,vehicle_no:String(a[idx('차량번호')]).trim(),driver_name:String(a[idx('운전자이름')]).trim(),shift_type:st&&st<'12:00'?'AM':'PM',shift_start:isoLocal(date,st),shift_end:isoLocal(ed,et),route_no:'',run_order:-1,support_route_no:'',support_run_order:null,source_format:'WORK_TIME'}); }
    } else if(idx('업체명')>=0 && idx('노선명')>=0 && idx('오전승무원명')>=0){
      for(const a of rows.slice(1)){ const date=normalizeDate(a[idx('운행일자')]), veh=String(a[idx('차량번호')]??'').trim(), route=String(a[idx('노선명')]??'').trim(), order=parseInt(a[idx('운행순위')]||-1,10), supRoute=String(a[idx('지원노선명')]??'').trim(), supOrder=parseInt(a[idx('지원운행순위')]||'',10); if(!date||!veh)continue; [['AM','오전승무원명'],['PM','오후승무원명']].forEach(([type,col])=>{const dn=String(a[idx(col)]??'').trim();if(dn)out.push({service_date:date,vehicle_no:veh,driver_name:dn,shift_type:type,shift_start:null,shift_end:null,route_no:route,run_order:Number.isFinite(order)?order:-1,support_route_no:supRoute,support_run_order:Number.isFinite(supOrder)?supOrder:null,source_format:'ROUTE_ASSIGN'});}); }
    }
    return out;
  }
  function readSheet(file){ return new Promise((resolve,reject)=>{ const fr=new FileReader(); fr.onload=()=>{try{const wb=XLSX.read(fr.result,{type:'array',cellDates:false}); const ws=wb.Sheets[wb.SheetNames[0]]; resolve(XLSX.utils.sheet_to_json(ws,{header:1,raw:true,defval:''}));}catch(e){reject(e)}};fr.onerror=reject;fr.readAsArrayBuffer(file);}); }
  async function loadDispatchList(){ const date=$('#dispatchDate')?.value; if(!date)return; const rows=await rpc('admin_list_dispatch',{p_token:token(),p_service_date:date}); $('#dispatchList').innerHTML=rows.length?`<div class="table-wrap"><table><thead><tr><th>차량</th><th>기사</th><th>구분</th><th>노선</th><th>순번</th><th>시작</th><th>종료</th><th>원본</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${esc(r.vehicle_no)}</td><td>${esc(r.driver_name)}</td><td>${r.shift_type}</td><td>${esc(r.route_no)}</td><td>${r.run_order>0?r.run_order:'-'}</td><td>${r.shift_start?fmtDT(r.shift_start):'-'}</td><td>${r.shift_end?fmtDT(r.shift_end):'-'}</td><td>${esc(r.source_format)}</td></tr>`).join('')}</tbody></table></div>`:'<div class="card empty">해당 날짜 배차가 없습니다.</div>'; }

  async function etasPage(){ $('#page').innerHTML=`<div class="card"><h3>교통안전공단 eTAS 리포트 업로드</h3><p class="notice">첨부 샘플 「리포트 다운로드t.xls」 형식을 기준으로 운전자명·분석월·안전수준·전월대비 행동점수·종합진단·권고문을 읽습니다. 공단 점수와 CDT 후보 이벤트는 구분하여 저장합니다.</p><input id="etasFile" type="file" accept=".xls,.xlsx"><div id="etasPreview"></div></div>`; $('#etasFile').onchange=()=>handleEtas($('#etasFile').files[0]); }
  async function handleEtas(file){ if(!file)return; const rows=await readSheet(file); const p=parseEtas(rows,file.name); if(!p.driver_name)return toast('운전자명을 찾지 못했습니다.',true); $('#etasPreview').innerHTML=`<div class="grid cols-3" style="margin-top:14px"><div class="card metric"><span class="label">운전자</span><span class="value">${esc(p.driver_name)}</span></div><div class="card metric good"><span class="label">안전운전 수준</span><span class="value">${esc(p.safety_level||'-')}</span></div><div class="card metric"><span class="label">종합점수</span><span class="value">${p.total_score??'-'}</span></div></div><div class="card" style="margin-top:14px"><b>종합진단</b><p>${esc(p.summary_text||'')}</p><div class="behavior-grid">${p.behaviors.map(b=>`<div class="behavior-item"><span>${esc(b.behavior)}</span><b>${b.current_score??'-'}</b><small>전월 ${b.previous_score??'-'} / 증감 ${b.change_score??'-'}</small></div>`).join('')}</div><button id="saveEtas" class="btn primary" style="margin-top:14px">리포트 저장·기사 공개</button></div>`; $('#saveEtas').onclick=async()=>{try{const r=await rpc('admin_import_etas',{p_token:token(),p_report:p});toast('eTAS 리포트를 저장했습니다.');}catch(e){toast(e.message,true)}}; }
  function parseEtas(rows,file){
    const flat=rows.flat().map(x=>String(x??'')).filter(Boolean); let driver='',level='',month='',summary='',weekday='',time='',trend='';
    for(const s of flat){ let m=s.match(/(.+?)님의 안전운전 수준은\s*["“]?([^"”]+)["”]?/); if(m){driver=m[1].trim();level=m[2].replace(/[.]/g,'').trim();} m=s.match(/분석기간\s*:/); if(m){} const mm=s.match(/(20\d{2})년\s*(\d{1,2})월/); if(mm&&!month)month=`${mm[1]}-${String(mm[2]).padStart(2,'0')}-01`; if(s.includes('안전운전수준은 업종평균대비'))summary=s.replace(/^⊙\s*/,''); if(s.includes('위험운전행동은 특히')){weekday=s.replace(/^⊙\s*/,''); const tm=s.match(/과\s*([^에]+)에 많이/); if(tm)time=tm[1].trim();} if(s.includes('월간 추이는'))trend=s.replace(/^⊙\s*/,''); }
    // 분석기간이 별도 셀인 경우 행을 찾아 우측 첫 값 사용
    for(const row of rows){ const i=row.findIndex(x=>String(x).includes('분석기간')); if(i>=0){ for(let j=i+1;j<row.length;j++){const s=String(row[j]||'');const m=s.match(/(20\d{2})년\s*(\d{1,2})월/);if(m){month=`${m[1]}-${String(m[2]).padStart(2,'0')}-01`;break;}} } }
    const behaviors=[]; const hdrRow=rows.findIndex(r=>r.some(x=>String(x).trim()==='구분')&&r.some(x=>String(x).includes('과속'))); if(hdrRow>=0){ const headers=[]; let current=''; for(let c=0;c<rows[hdrRow].length;c++){let v=String(rows[hdrRow][c]||'').replace(/\s/g,''); if(v&&v!=='구분'){current=v;} if(current)headers[c]=current;} if(rows[hdrRow+1]){for(let c=0;c<rows[hdrRow+1].length;c++){let sub=String(rows[hdrRow+1][c]||'').replace(/\s/g,''); if(sub&&headers[c]==='급회전')headers[c]=`급회전-${sub}`;}}
      const data=[]; for(let r=hdrRow+2;r<Math.min(rows.length,hdrRow+8);r++){const label=String(rows[r]?.[1]||'').trim(); if(/^20\d{2}-\d{2}월$/.test(label)||label==='증감')data.push({label,row:rows[r]});}
      const cur=data.find(x=>month&&x.label.startsWith(month.slice(0,7)))||data.filter(x=>x.label!=='증감').slice(-1)[0]; const prev=data.filter(x=>x.label!=='증감'&&x!==cur).slice(-1)[0]; const ch=data.find(x=>x.label==='증감'); const seen=new Set(); if(cur){for(let c=0;c<cur.row.length;c++){const h=headers[c]; if(!h||seen.has(h)||h==='합계')continue; const cv=cur.row[c]; if(cv===''||cv==null)continue; seen.add(h); behaviors.push({behavior:h,current_score:String(cv),previous_score:prev?String(prev.row[c]??''):'',change_score:ch?String(ch.row[c]??''):''});} const hi=headers.findIndex(x=>x==='합계'); if(hi>=0) var total=Number(cur.row[hi]||0);}
    }
    const rec=[]; for(let i=0;i<rows.length;i++){const t=String(rows[i]?.[1]||'');if(/^\d+\.\s*["“]/.test(t)){const body=String(rows[i+1]?.[1]||'').trim();if(body)rec.push({title:t,text:body});}}
    return {driver_name:driver,analysis_month:month||new Date().toISOString().slice(0,7)+'-01',safety_level:level,total_score:typeof total==='number'?total:null,summary_text:summary,weekday_text:weekday,time_text:time,trend_text:trend,recommendations:rec,behaviors,source_file:file};
  }

  async function changesPage(){ const today=new Date().toISOString().slice(0,10); $('#page').innerHTML=`<div class="card"><h3>BIS 차량변경 감시</h3><p class="notice">실시간 감시는 회사 PC의 <b>collector/daewoon_collector.py</b>가 수행합니다. TAGO 노선별 버스위치에서 오늘 배차와 다른 차량이 지속 관측되면 교체 후보를 판정하고 <b>변경 이벤트만</b> Supabase에 저장합니다.</p><p class="small muted">창원시 기존 API는 2027-01-01 종료 예정이므로 수집기는 국토교통부 TAGO API를 기본 사용합니다.</p></div><div class="section-title"><h3>차량변경 이력</h3></div><div id="changeList"></div>`; const d=await rpc('admin_dashboard',{p_token:token(),p_service_date:today}); $('#changeList').innerHTML=tableChanges(d.changes); }

  async function driversPage(){ const rows=await rpc('admin_list_users',{p_token:token()}); $('#page').innerHTML=`<div class="notice">배차표 업로드 시 기사 이름을 로그인 ID로 자동 생성합니다. 초기 비밀번호는 1111이며 첫 로그인 후 변경이 강제됩니다.</div><div class="section-title"><h3>사용자</h3></div><div class="table-wrap"><table><thead><tr><th>ID</th><th>이름</th><th>역할</th><th>비밀번호변경</th><th>최근로그인</th><th></th></tr></thead><tbody>${rows.map(r=>`<tr><td>${esc(r.login_id)}</td><td><b>${esc(r.display_name)}</b></td><td>${r.role}</td><td>${r.must_change_password?'필요':'완료'}</td><td>${r.last_login_at?fmtDT(r.last_login_at):'-'}</td><td>${r.role==='driver'?`<button class="btn danger resetpw" data-id="${r.id}">1111로 초기화</button>`:''}</td></tr>`).join('')}</tbody></table></div>`; $$('.resetpw').forEach(b=>b.onclick=async()=>{if(!confirm('비밀번호를 1111로 초기화할까요?'))return;try{await rpc('admin_reset_password',{p_token:token(),p_user_id:b.dataset.id});toast('초기화했습니다.');driversPage();}catch(e){toast(e.message,true)}}); }
  async function ackPage(){ const rows=await rpc('admin_ack_status',{p_token:token(),p_limit:300}); $('#page').innerHTML=`<div class="notice">기사가 본인의 분석결과에서 <b>확인했습니다</b>를 누른 시각을 관리합니다.</div><div class="section-title"><h3>확인현황</h3></div><div class="table-wrap"><table><thead><tr><th>기사</th><th>기간</th><th>자료</th><th>공개일</th><th>확인여부</th><th>확인시각</th></tr></thead><tbody>${rows.map(r=>`<tr><td><b>${esc(r.driver_name)}</b></td><td>${r.period_start} ~ ${r.period_end}</td><td>${esc(r.title)}</td><td>${fmtDT(r.published_at)}</td><td>${r.acknowledged_at?'<span class="ack-ok">확인</span>':'<span class="ack-wait">미확인</span>'}</td><td>${r.acknowledged_at?fmtDT(r.acknowledged_at):'-'}</td></tr>`).join('')}</tbody></table></div>`; }
  async function auditPage(){ const rows=await rpc('admin_audit',{p_token:token(),p_limit:300}); $('#page').innerHTML=`<div class="table-wrap"><table><thead><tr><th>시각</th><th>작업자</th><th>행위</th><th>대상</th><th>상세</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${fmtDT(r.created_at)}</td><td>${esc(r.user_name)}</td><td>${esc(r.action)}</td><td>${esc(r.entity_type||'')} ${esc(r.entity_id||'')}</td><td>${esc(JSON.stringify(r.detail||{}))}</td></tr>`).join('')}</tbody></table></div>`; }

  async function driverDashboard(){ const d=await rpc('driver_dashboard',{p_token:token(),p_limit:20}); const latest=d.etas?.[0], pub=d.publications?.[0]; $('#page').innerHTML=`<div class="card driver-hero"><span class="kicker">MY SAFE DRIVE</span><h2>${esc(state.session.display_name)} 기사님</h2><div class="grid cols-3"><div class="metric"><span class="label muted">최근 eTAS 안전수준</span><span class="level">${esc(latest?.safety_level||'자료 없음')}</span></div><div class="metric"><span class="label muted">최근 종합점수</span><span class="level">${latest?.total_score??'-'}</span></div><div class="metric"><span class="label muted">공개자료 확인</span><span class="level">${pub?(pub.acknowledged?'완료':'미확인'):'-'}</span></div></div></div>
    ${latest?`<div class="section-title"><h3>교통안전공단 분석</h3></div><div class="card"><p>${esc(latest.summary_text||'')}</p><p>${esc(latest.weekday_text||'')}</p><p>${esc(latest.trend_text||'')}</p><div class="behavior-grid">${(latest.behaviors||[]).map(b=>`<div class="behavior-item"><span>${esc(b.behavior)}</span><b>${b.current_score??'-'}</b></div>`).join('')}</div></div>`:''}
    <div class="section-title"><h3>나에게 공개된 분석결과</h3></div>${renderPublications(d.publications)}
    <div class="section-title"><h3>최근 CDT 후보 이벤트 요약</h3></div>${tableTaco(d.taco_daily||[])}`;
    $$('.ackbtn').forEach(b=>b.onclick=async()=>{try{await rpc('driver_acknowledge',{p_token:token(),p_publication_id:Number(b.dataset.id),p_comment:null});toast('확인 처리했습니다.');driverDashboard();}catch(e){toast(e.message,true)}});
  }
  function renderPublications(rows){ if(!rows?.length)return '<div class="card empty">공개된 분석자료가 없습니다.</div>'; return rows.map(p=>`<div class="pub-card"><div class="pub-head"><div><b>${esc(p.title)}</b><div class="small muted">${p.period_start} ~ ${p.period_end} · ${esc(p.source)}</div></div><div>${p.acknowledged?'<span class="badge good">확인완료</span>':`<button class="btn primary ackbtn" data-id="${p.id}">확인했습니다</button>`}</div></div><p>${esc(p.summary?.summary_text||'')}</p>${p.source==='CDT'?`<div class="small muted" style="margin-bottom:10px">운행거리 ${n(p.summary.distance_km).toFixed(1)}km · 차량 ${(p.summary.vehicles||[]).map(esc).join(', ')||'-'} · 노선 ${(p.summary.routes||[]).map(esc).join(', ')||'-'} · 데이터품질 ${esc(p.summary.data_quality||'-')}</div><div class="behavior-grid"><div class="behavior-item"><span>급출발 후보</span><b>${p.summary.rapid_start||0}</b></div><div class="behavior-item"><span>급가속 후보</span><b>${p.summary.rapid_accel||0}</b></div><div class="behavior-item"><span>급감속 후보</span><b>${p.summary.rapid_decel||0}</b></div><div class="behavior-item"><span>급정지 후보</span><b>${p.summary.rapid_stop||0}</b></div><div class="behavior-item"><span>관리속도 초과 후보</span><b>${p.summary.speed_watch||0}</b></div></div>`:''}</div>`).join(''); }
  async function driverHistory(){ const d=await rpc('driver_dashboard',{p_token:token(),p_limit:100}); $('#page').innerHTML=`<div class="section-title"><h3>배차·운행이력</h3></div>${d.dispatch?.length?`<div class="table-wrap"><table><thead><tr><th>일자</th><th>차량</th><th>노선</th><th>순번</th><th>근무</th></tr></thead><tbody>${d.dispatch.map(r=>`<tr><td>${r.service_date}</td><td>${esc(r.vehicle_no)}</td><td>${esc(r.route_no)}</td><td>${r.run_order>0?r.run_order:'-'}</td><td>${r.shift_start?fmtDT(r.shift_start):r.shift_type}</td></tr>`).join('')}</tbody></table></div>`:'<div class="card empty">배차 이력이 없습니다.</div>'}<div class="section-title"><h3>차량교체 이력</h3></div>${tableChanges(d.vehicle_changes||[])}`; }

  function settingsPage(){ $('#page').innerHTML=`<div class="grid cols-2"><div class="card"><h3>비밀번호 변경</h3><div class="form-grid"><label>현재 비밀번호<input id="spOld" type="password"></label><label>새 비밀번호<input id="spNew" type="password"></label></div><button id="spBtn" class="btn primary">변경</button></div>${state.session.role==='admin'?`<div class="card"><h3>Supabase 연결</h3><label>URL<input id="cfgUrl" value="${esc(state.cfg.url)}"></label><label>anon/publishable key<textarea id="cfgKey" rows="3">${esc(state.cfg.key)}</textarea></label><button id="cfgBtn" class="btn secondary">브라우저 설정 저장</button></div><div class="card span-2"><h3>자동수집기 설치</h3><p>회사 PC에서 <code>collector/setup_windows.bat</code>를 실행하고 <code>collector_config.json</code>에 Supabase URL·anon key, 관리자 로그인, TAGO 서비스키를 입력합니다.</p><div class="code-note">감시 폴더 기본값: E:\\Choyoung\\ADTviewer\\Data<br>BIS: 국토교통부 TAGO 버스위치정보<br>저장정책: 실시간 스냅샷은 로컬 상태만 유지, 차량변경 이벤트만 Supabase 저장</div></div>`:''}</div>`; $('#spBtn').onclick=async()=>{try{await rpc('app_change_password',{p_token:token(),p_old_password:$('#spOld').value,p_new_password:$('#spNew').value});toast('비밀번호를 변경했습니다.');}catch(e){toast(e.message,true)}}; if($('#cfgBtn'))$('#cfgBtn').onclick=()=>{saveCfg($('#cfgUrl').value.trim(),$('#cfgKey').value.trim());toast('저장했습니다.');}; }

  init();
})();
