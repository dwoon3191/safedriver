(() => {
  'use strict';

  const $ = selector => document.querySelector(selector);
  const $$ = selector => [...document.querySelectorAll(selector)];
  const state = {
    cfg: null,
    session: null,
    page: 'dashboard',
    refreshTimer: null,
  };

  const esc = value => String(value ?? '').replace(/[&<>'"]/g, char => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
  })[char]);
  const num = value => Number(value || 0);
  const fmtDate = value => {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? (value || '') : date.toLocaleDateString('ko-KR');
  };
  const fmtDT = value => {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? (value || '') : date.toLocaleString('ko-KR', { hour12: false });
  };
  const todayISO = () => new Date().toISOString().slice(0, 10);

  function toast(message, error = false) {
    const element = $('#toast');
    element.textContent = message;
    element.className = `toast show${error ? ' error' : ''}`;
    setTimeout(() => { element.className = 'toast'; }, 3200);
  }

  function show(id) {
    ['setupView', 'loginView', 'appView'].forEach(view => $(`#${view}`).classList.add('hidden'));
    $(`#${id}`).classList.remove('hidden');
  }

  function openModal(html) {
    $('#modalBody').innerHTML = html;
    $('#modal').classList.remove('hidden');
  }

  function closeModal() {
    $('#modal').classList.add('hidden');
    $('#modalClose').classList.remove('hidden');
  }

  function clearRefreshTimer() {
    if (state.refreshTimer) {
      clearInterval(state.refreshTimer);
      state.refreshTimer = null;
    }
  }

  $('#modalClose').onclick = closeModal;
  $('#modal').addEventListener('click', event => {
    if (event.target.id === 'modal') closeModal();
  });

  function loadCfg() {
    const deployed = window.DAEWOON_CONFIG || {};
    const saved = JSON.parse(localStorage.getItem('daewoon_supabase') || '{}');
    state.cfg = {
      url: String(deployed.url || saved.url || '').replace(/\/$/, ''),
      key: deployed.key || saved.key || '',
      source: deployed.url && deployed.key ? 'config.js' : (saved.url && saved.key ? 'browser' : ''),
    };
    return Boolean(state.cfg.url && state.cfg.key);
  }

  function saveCfg(url, key) {
    localStorage.setItem('daewoon_supabase', JSON.stringify({
      url: String(url || '').replace(/\/$/, ''),
      key: key || '',
    }));
    loadCfg();
  }

  function downloadConfigJs(url, key) {
    const content = `window.DAEWOON_CONFIG = ${JSON.stringify({
      url: String(url || '').replace(/\/$/, ''),
      key: String(key || ''),
    }, null, 2)};\n`;
    const blob = new Blob([content], { type: 'text/javascript;charset=utf-8' });
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = 'config.js';
    link.click();
    URL.revokeObjectURL(link.href);
  }

  async function rpc(functionName, body = {}) {
    if (!state.cfg?.url || !state.cfg?.key) throw new Error('Supabase 연결정보가 없습니다.');
    const response = await fetch(`${state.cfg.url}/rest/v1/rpc/${functionName}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: state.cfg.key,
        Authorization: `Bearer ${state.cfg.key}`,
      },
      body: JSON.stringify(body),
    });
    const text = await response.text();
    let data;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    if (!response.ok) {
      throw new Error(data?.message || data?.hint || text || `HTTP ${response.status}`);
    }
    return data;
  }

  const token = () => state.session?.token || '';
  function saveSession(session) {
    state.session = session;
    localStorage.setItem('daewoon_session', JSON.stringify(session));
  }
  function clearSession() {
    state.session = null;
    localStorage.removeItem('daewoon_session');
  }

  async function init() {
    loadCfg();
    if (!state.cfg.url || !state.cfg.key) {
      show('setupView');
      return;
    }
    const saved = JSON.parse(localStorage.getItem('daewoon_session') || 'null');
    if (saved?.token) {
      try {
        const me = await rpc('app_me', { p_token: saved.token });
        saveSession({ ...saved, ...me });
        enterApp();
        return;
      } catch {
        clearSession();
      }
    }
    show('loginView');
  }

  $('#saveSetupBtn').onclick = () => {
    const url = $('#setupUrl').value.trim();
    const key = $('#setupKey').value.trim();
    if (!url || !key) return toast('URL과 key를 모두 입력하세요.', true);
    saveCfg(url, key);
    toast('브라우저 연결정보를 저장했습니다. 운영 배포용 config.js도 생성할 수 있습니다.');
    if (confirm('기사 휴대전화에서 설정 없이 사용하도록 config.js를 내려받을까요?')) {
      downloadConfigJs(url, key);
    }
    show('loginView');
  };
  if ($('#openSetupBtn')) $('#openSetupBtn').onclick = () => {
    $('#setupUrl').value = state.cfg?.url || '';
    $('#setupKey').value = state.cfg?.key || '';
    show('setupView');
  };
  $('#loginBtn').onclick = login;
  $('#loginPw').addEventListener('keydown', event => { if (event.key === 'Enter') login(); });

  async function login() {
    try {
      const id = $('#loginId').value.trim();
      const password = $('#loginPw').value;
      if (!id || !password) return toast('아이디와 비밀번호를 입력하세요.', true);
      const session = await rpc('app_login', { p_login_id: id, p_password: password });
      saveSession(session);
      enterApp();
    } catch (error) {
      toast(error.message, true);
    }
  }

  $('#logoutBtn').onclick = async () => {
    clearRefreshTimer();
    try { await rpc('app_logout', { p_token: token() }); } catch {}
    clearSession();
    show('loginView');
  };
  $('#menuBtn').onclick = () => $('.sidebar').classList.toggle('open');

  function enterApp() {
    show('appView');
    $('#userBox').innerHTML = `<b>${esc(state.session.display_name)}</b><br><span>${state.session.role === 'admin' ? '관리자' : '운전자'}</span>`;
    buildNav();
    if (state.session.must_change_password) setTimeout(forcePasswordChange, 150);
    navigate('dashboard');
  }

  function buildNav() {
    const admin = [
      ['dashboard', '▦ 대시보드'],
      ['dispatch', '▤ 일일 배차표'],
      ['timetable', '▦ 노선 운행시간표'],
      ['reports', '◫ 기사 운행분석'],
      ['changes', '⇄ 차량변경'],
      ['collector', '● 수집현황'],
      ['drivers', '♙ 기사 계정'],
      ['acks', '✓ 확인현황'],
      ['audit', '◷ 작업이력'],
      ['settings', '⚙ 설정/설치'],
    ];
    const driver = [
      ['dashboard', '▦ 나의 운행분석'],
      ['history', '▤ 운행이력'],
      ['settings', '⚙ 비밀번호/정보'],
    ];
    $('#nav').innerHTML = (state.session.role === 'admin' ? admin : driver)
      .map(([id, title]) => `<button class="nav-btn" data-page="${id}">${title}</button>`)
      .join('');
    $$('.nav-btn').forEach(button => {
      button.onclick = () => {
        navigate(button.dataset.page);
        $('.sidebar').classList.remove('open');
      };
    });
  }

  function navigate(page) {
    clearRefreshTimer();
    state.page = page;
    $$('.nav-btn').forEach(button => button.classList.toggle('active', button.dataset.page === page));
    const titles = {
      dashboard: state.session.role === 'admin' ? '운영 대시보드' : '나의 안전운전 분석',
      dispatch: '일일 배차표 관리',
      timetable: '노선별 운행시간표 관리',
      reports: '기사별 SafeDrive 운행분석',
      changes: 'BIS 차량변경',
      collector: '자료수집·Collector 현황',
      drivers: '기사 계정',
      acks: '분석결과 확인현황',
      audit: '작업 이력',
      history: '나의 운행이력',
      settings: '설정',
    };
    $('#pageTitle').textContent = titles[page] || page;
    $('#pageSubtitle').textContent = '대운교통 SafeDrive AI · 배차 / 운행시간표 / BIS / CDT 기반 기사 피드백';
    $('#topActions').innerHTML = '';
    renderPage(page).catch(error => {
      $('#page').innerHTML = `<div class="notice warn">${esc(error.message)}</div>`;
      toast(error.message, true);
    });
  }
  window.appGo = navigate;

  async function renderPage(page) {
    if (state.session.role === 'admin') {
      if (page === 'dashboard') return adminDashboard();
      if (page === 'dispatch') return dispatchPage();
      if (page === 'timetable') return timetablePage();
      if (page === 'reports') return reportsPage();
      if (page === 'changes') return changesPage();
      if (page === 'collector') return collectorPage();
      if (page === 'drivers') return driversPage();
      if (page === 'acks') return ackPage();
      if (page === 'audit') return auditPage();
      if (page === 'settings') return settingsPage();
    } else {
      if (page === 'dashboard') return driverDashboard();
      if (page === 'history') return driverHistory();
      if (page === 'settings') return settingsPage();
    }
  }

  function forcePasswordChange() {
    openModal(`<h2>첫 로그인 비밀번호 변경</h2>
      <p class="notice warn">초기 비밀번호 1111은 계속 사용할 수 없습니다.</p>
      <div class="form-grid">
        <label>현재 비밀번호<input id="oldpw" type="password" value="1111"></label>
        <label>새 비밀번호<input id="newpw" type="password" placeholder="6자 이상"></label>
        <label class="span-2">새 비밀번호 확인<input id="newpw2" type="password"></label>
      </div>
      <button id="changePwBtn" class="btn primary full">비밀번호 변경</button>`);
    $('#modalClose').classList.add('hidden');
    $('#changePwBtn').onclick = async () => {
      const first = $('#newpw').value;
      const second = $('#newpw2').value;
      if (first !== second) return toast('새 비밀번호가 일치하지 않습니다.', true);
      try {
        await rpc('app_change_password', {
          p_token: token(),
          p_old_password: $('#oldpw').value,
          p_new_password: first,
        });
        state.session.must_change_password = false;
        saveSession(state.session);
        closeModal();
        toast('비밀번호를 변경했습니다.');
      } catch (error) {
        toast(error.message, true);
      }
    };
  }

  function badge(value) {
    const text = String(value || '');
    const css = /running|online|high|양호|완료|확인|good/i.test(text)
      ? 'good'
      : /error|offline|low|위험|미확인|limited|실패/i.test(text)
        ? 'bad'
        : 'warn';
    return `<span class="badge ${css}">${esc(text)}</span>`;
  }

  function tableChanges(rows) {
    if (!rows?.length) return '<div class="card empty">확정된 실제차량 연결정보가 없습니다. Collector의 노선·위치 API 조회상태와 시간표 적용일을 확인하세요.</div>';
    return `<div class="table-wrap"><table><thead><tr>
      <th>유효시작</th><th>유형</th><th>노선</th><th>순번</th><th>기사</th><th>배차차량</th><th>실제차량</th><th>확인횟수</th><th>신뢰도</th>
      </tr></thead><tbody>${rows.map(row => `<tr>
      <td>${fmtDT(row.effective_from_at || row.detected_at)}</td><td>${esc(row.change_type === 'START_SUBSTITUTE' ? '출발 전 대체' : '운행 중 교체')}</td>
      <td>${esc(row.route_no)}</td><td>${row.run_order > 0 ? row.run_order : '-'}</td>
      <td>${esc(row.driver_name)}</td><td>${esc(row.planned_vehicle || row.old_vehicle)}</td><td><b>${esc(row.actual_vehicle || row.new_vehicle)}</b></td>
      <td>${row.confirmed_polls || '-'}</td><td>${badge(row.confidence)}</td></tr>`).join('')}</tbody></table></div>`;
  }

  function tableTaco(rows) {
    if (!rows?.length) return '<div class="card empty">분석된 CDT 자료가 없습니다.</div>';
    return `<div class="table-wrap"><table><thead><tr>
      <th>운행일</th><th>기사</th><th>차량</th><th>노선</th><th>거리</th><th>점수</th><th>수준</th><th>급출발</th><th>급가속</th><th>급감속</th><th>급정지</th><th>과속후보</th><th>수집지연</th><th>매칭</th>
      </tr></thead><tbody>${rows.map(row => `<tr>
      <td>${esc(row.service_date || '')}</td><td><b>${esc(row.driver_name)}</b></td><td>${esc(row.vehicle_no)}</td><td>${esc(row.route_no)}</td>
      <td>${num(row.distance_km).toFixed(1)}km</td><td><b>${row.safety_score ?? '-'}</b></td><td>${badge(row.safety_level || '-')}</td>
      <td>${row.rapid_start || 0}</td><td>${row.rapid_accel || 0}</td><td>${row.rapid_decel || 0}</td><td>${row.rapid_stop || 0}</td><td>${row.speed_watch || 0}</td>
      <td>${row.late_days ? `${row.late_days}일` : '당일'}</td><td>${badge(row.match_status || row.data_quality || '-')}</td>
      </tr>`).join('')}</tbody></table></div>`;
  }

  function tableImports(rows) {
    if (!rows?.length) return '<div class="card empty">수집 이력이 없습니다.</div>';
    return `<div class="table-wrap"><table><thead><tr><th>수집시각</th><th>파일</th><th>차량</th><th>운행일</th><th>지연</th><th>상태</th><th>매칭/미매칭</th><th>레코드</th></tr></thead><tbody>${rows.map(row => `<tr>
      <td>${fmtDT(row.imported_at || row.collected_at)}</td><td>${esc(row.source_file)}</td><td>${esc(row.vehicle_no)}</td><td>${esc(row.service_date)}</td>
      <td>${row.delay_days ? `${row.delay_days}일` : '당일'}</td><td>${badge(row.match_status || 'matched')}</td>
      <td>${row.matched_seconds || 0}/${row.unmatched_seconds || 0}초</td><td>${row.record_count}</td></tr>`).join('')}</tbody></table></div>`;
  }

  async function adminDashboard() {
    const date = todayISO();
    const [dashboard, collector] = await Promise.all([
      rpc('admin_dashboard', { p_token: token(), p_service_date: date }),
      rpc('admin_collector_status', { p_token: token(), p_limit: 10 }).catch(() => ({ agents: [] })),
    ]);
    const agent = collector.agents?.[0];
    $('#page').innerHTML = `
      <div class="grid cols-4">
        <div class="card metric"><span class="label">등록 기사</span><span class="value">${dashboard.counts.drivers}</span></div>
        <div class="card metric"><span class="label">오늘 배차</span><span class="value">${dashboard.counts.dispatch}</span></div>
        <div class="card metric warn"><span class="label">오늘 차량변경</span><span class="value">${dashboard.counts.vehicle_changes}</span></div>
        <div class="card metric ${agent?.online ? 'good' : 'bad'}"><span class="label">Collector</span><span class="value small-value">${agent?.online ? 'ONLINE' : 'OFFLINE'}</span></div>
      </div>
      ${agent ? `<div class="card status-strip"><b>${esc(agent.agent_id)}</b><span>마지막 연결 ${fmtDT(agent.last_heartbeat_at)}</span><span>CDT ${fmtDT(agent.last_taco_scan_at) || '-'}</span><span>BIS ${fmtDT(agent.last_bis_poll_at) || '-'}</span><span>지연수집 대기 ${agent.counters?.pending_cdt || 0}건</span></div>` : ''}
      <div class="section-title"><h3>오늘 차량변경</h3><button class="btn secondary" onclick="window.appGo('changes')">전체보기</button></div>
      ${tableChanges(dashboard.changes)}
      <div class="section-title"><h3>오늘 기사 운행분석</h3><button class="btn secondary" onclick="window.appGo('reports')">기사별 보기</button></div>
      ${tableTaco(dashboard.taco_daily)}
      <div class="section-title"><h3>최근 타코/CDT 자동수집</h3><button class="btn secondary" onclick="window.appGo('collector')">수집현황</button></div>
      ${tableImports(dashboard.recent_imports)}`;
  }

  // ---------- Dispatch multi-file import ----------
  async function dispatchPage() {
    const today = todayISO();
    $('#page').innerHTML = `<div class="card">
      <h3>배차표 엑셀 다중 업로드</h3>
      <p class="notice">일자별 배차표를 여러 개 동시에 선택할 수 있습니다. 파일명 <b>YYYYMMDD_배차.xls</b>에서도 운행일자를 인식하며, 시트·헤더 위치가 달라도 자동 탐색합니다.</p>
      <div class="dropzone" id="dispatchDrop"><input id="dispatchFile" type="file" accept=".xls,.xlsx,.csv" multiple><p>기사 근무파일과 일일 노선·운행순위 파일을 함께 여러 개 선택하거나 끌어놓으세요.</p></div>
      <div id="dispatchPreview"></div>
    </div>
    <div class="section-title"><h3>등록된 배차</h3><div class="toolbar"><input id="dispatchDate" type="date" value="${today}"><button id="loadDispatch" class="btn secondary">조회</button></div></div>
    <div id="dispatchList"></div>`;
    const input = $('#dispatchFile');
    input.onchange = () => handleDispatchFiles([...input.files]);
    const dropzone = $('#dispatchDrop');
    ['dragenter', 'dragover'].forEach(name => dropzone.addEventListener(name, event => {
      event.preventDefault(); dropzone.classList.add('drag');
    }));
    ['dragleave', 'drop'].forEach(name => dropzone.addEventListener(name, event => {
      event.preventDefault(); dropzone.classList.remove('drag');
    }));
    dropzone.addEventListener('drop', event => handleDispatchFiles([...event.dataTransfer.files]));
    $('#loadDispatch').onclick = loadDispatchList;
    loadDispatchList();
  }

  const canonical = value => String(value ?? '')
    .replace(/[\s\n\r*·ㆍ:()\[\]_-]/g, '')
    .toLowerCase();

  const FIELD_ALIASES = {
    vehicle: ['차량번호', '차량', '차호', '차번', '버스번호'],
    driver: ['운전자이름', '운전자명', '기사명', '운전기사', '승무원명', '성명'],
    startDate: ['근무시작일자', '근무시작일', '시작일자', '시작일'],
    endDate: ['근무종료일자', '근무종료일', '종료일자', '종료일'],
    startTime: ['근무시작시간', '시작시간', '출근시간'],
    endTime: ['근무종료시간', '종료시간', '퇴근시간'],
    serviceDate: ['운행일자', '배차일자', '운행일', '일자'],
    company: ['업체명', '회사명'],
    route: ['노선명', '노선번호', '노선'],
    order: ['운행순위', '순번', '회차'],
    amDriver: ['오전승무원명', '오전기사명', '오전승무원', '오전기사'],
    pmDriver: ['오후승무원명', '오후기사명', '오후승무원', '오후기사'],
    amDeparture: ['오전출발시간', '오전출발', '오전출발시각', 'am출발시간'],
    pmDeparture: ['오후출발시간', '오후출발', '오후출발시각', 'pm출발시간'],
    supportRoute: ['지원노선명', '지원노선'],
    supportOrder: ['지원운행순위', '지원순위'],
  };
  const ALIAS_CANON = Object.fromEntries(Object.entries(FIELD_ALIASES).map(([key, values]) => [key, values.map(canonical)]));

  function findColumn(header, field) {
    const normalized = header.map(canonical);
    return normalized.findIndex(value => ALIAS_CANON[field].includes(value));
  }

  function inferDateFromFilename(filename) {
    const match = String(filename || '').match(/(20\d{6})/);
    return match ? `${match[1].slice(0, 4)}-${match[1].slice(4, 6)}-${match[1].slice(6, 8)}` : null;
  }

  function findDateInRows(rows) {
    for (const row of rows.slice(0, 30)) {
      for (const cell of row) {
        const date = normalizeDate(cell);
        if (date) return date;
      }
    }
    return null;
  }

  function detectHeader(rows) {
    for (let index = 0; index < Math.min(rows.length, 50); index++) {
      const header = rows[index] || [];
      const vehicle = findColumn(header, 'vehicle');
      const driver = findColumn(header, 'driver');
      const amDriver = findColumn(header, 'amDriver');
      const pmDriver = findColumn(header, 'pmDriver');
      const route = findColumn(header, 'route');
      const order = findColumn(header, 'order');
      const amDeparture = findColumn(header, 'amDeparture');
      const pmDeparture = findColumn(header, 'pmDeparture');
      if (vehicle >= 0 && driver >= 0) return { index, type: 'WORK_TIME', header };
      if (vehicle >= 0 && route >= 0 && (amDriver >= 0 || pmDriver >= 0)) return { index, type: 'ROUTE_ASSIGN', header };
      if (vehicle >= 0 && route >= 0 && order >= 0 && (amDeparture >= 0 || pmDeparture >= 0)) return { index, type: 'DAILY_ROUTE', header };
    }
    return null;
  }

  function normalizeVehicle(value) {
    const text = String(value ?? '').replace(/\s/g, '');
    if (/^\d{4}$/.test(text)) return `경남71자${text}`;
    const match = text.match(/(?:경남)?71자?(\d{4})$/);
    return match ? `경남71자${match[1]}` : text;
  }

  function excelTimeToHHMM(value) {
    if (value === null || value === undefined || value === '') return null;
    if (typeof value === 'number') {
      const minutes = Math.round((value % 1) * 1440);
      return `${String(Math.floor(minutes / 60) % 24).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`;
    }
    const text = String(value).trim();
    const match = text.match(/(\d{1,2}):(\d{2})/);
    return match ? `${match[1].padStart(2, '0')}:${match[2]}` : null;
  }

  function normalizeDate(value) {
    if (value === null || value === undefined || value === '') return null;
    if (value instanceof Date && !Number.isNaN(value.getTime())) return value.toISOString().slice(0, 10);
    const text = String(value).trim();
    if (/^20\d{6}$/.test(text)) return `${text.slice(0, 4)}-${text.slice(4, 6)}-${text.slice(6, 8)}`;
    let match = text.match(/(20\d{2})[.\/-]\s*(\d{1,2})[.\/-]\s*(\d{1,2})/);
    if (match) return `${match[1]}-${String(match[2]).padStart(2, '0')}-${String(match[3]).padStart(2, '0')}`;
    if (typeof value === 'number' && value > 30000 && typeof XLSX !== 'undefined') {
      const decoded = XLSX.SSF.parse_date_code(value);
      if (decoded) return `${decoded.y}-${String(decoded.m).padStart(2, '0')}-${String(decoded.d).padStart(2, '0')}`;
    }
    return null;
  }

  const isoLocal = (date, hhmm) => date && hhmm ? `${date}T${hhmm}:00+09:00` : null;

  function normalizeDispatch(rows, filename, sheetName) {
    if (!rows?.length) return [];
    const detected = detectHeader(rows);
    if (!detected) return [];
    const header = detected.header;
    const dataRows = rows.slice(detected.index + 1);
    const fallbackDate = inferDateFromFilename(filename) || findDateInRows(rows);
    const out = [];

    if (detected.type === 'WORK_TIME') {
      const vehicleIndex = findColumn(header, 'vehicle');
      const driverIndex = findColumn(header, 'driver');
      const startDateIndex = findColumn(header, 'startDate');
      const endDateIndex = findColumn(header, 'endDate');
      const startTimeIndex = findColumn(header, 'startTime');
      const endTimeIndex = findColumn(header, 'endTime');
      for (const row of dataRows) {
        const serviceDate = normalizeDate(row[startDateIndex]) || fallbackDate;
        const endDate = normalizeDate(row[endDateIndex]) || serviceDate;
        const vehicleNo = normalizeVehicle(row[vehicleIndex]);
        const driverName = String(row[driverIndex] ?? '').trim();
        const startTime = excelTimeToHHMM(row[startTimeIndex]);
        const endTime = excelTimeToHHMM(row[endTimeIndex]);
        if (!serviceDate || !vehicleNo || !driverName) continue;
        out.push({
          service_date: serviceDate,
          vehicle_no: vehicleNo,
          driver_name: driverName,
          shift_type: startTime && startTime < '12:00' ? 'AM' : 'PM',
          shift_start: isoLocal(serviceDate, startTime),
          shift_end: isoLocal(endDate, endTime),
          route_no: '', run_order: -1, support_route_no: '', support_run_order: null,
          source_format: 'WORK_TIME', source_sheet: sheetName,
        });
      }
    } else if (detected.type === 'DAILY_ROUTE') {
      const vehicleIndex = findColumn(header, 'vehicle');
      const dateIndex = findColumn(header, 'serviceDate');
      const routeIndex = findColumn(header, 'route');
      const orderIndex = findColumn(header, 'order');
      const amDepartureIndex = findColumn(header, 'amDeparture');
      const pmDepartureIndex = findColumn(header, 'pmDeparture');
      for (const row of dataRows) {
        const serviceDate = normalizeDate(row[dateIndex]) || fallbackDate;
        const vehicleNo = normalizeVehicle(row[vehicleIndex]);
        const routeNo = normalizeRouteNo(row[routeIndex]);
        const runOrder = parseInt(row[orderIndex] || -1, 10);
        if (!serviceDate || !vehicleNo || !routeNo) continue;
        [['AM', amDepartureIndex], ['PM', pmDepartureIndex]].forEach(([shiftType, column]) => {
          if (column < 0) return;
          const departure = excelTimeToHHMM(row[column]);
          if (!departure) return;
          out.push({
            service_date: serviceDate,
            vehicle_no: vehicleNo,
            driver_name: '',
            shift_type: shiftType,
            shift_start: isoLocal(serviceDate, departure),
            shift_end: null,
            route_no: routeNo,
            run_order: Number.isFinite(runOrder) ? runOrder : -1,
            support_route_no: '', support_run_order: null,
            source_format: 'DAILY_ROUTE', source_sheet: sheetName,
          });
        });
      }
    } else {
      const vehicleIndex = findColumn(header, 'vehicle');
      const dateIndex = findColumn(header, 'serviceDate');
      const routeIndex = findColumn(header, 'route');
      const orderIndex = findColumn(header, 'order');
      const amIndex = findColumn(header, 'amDriver');
      const pmIndex = findColumn(header, 'pmDriver');
      const supportRouteIndex = findColumn(header, 'supportRoute');
      const supportOrderIndex = findColumn(header, 'supportOrder');
      for (const row of dataRows) {
        const serviceDate = normalizeDate(row[dateIndex]) || fallbackDate;
        const vehicleNo = normalizeVehicle(row[vehicleIndex]);
        const routeNo = String(row[routeIndex] ?? '').trim();
        const runOrder = parseInt(row[orderIndex] || -1, 10);
        const supportRoute = String(row[supportRouteIndex] ?? '').trim();
        const supportOrder = parseInt(row[supportOrderIndex] || '', 10);
        if (!serviceDate || !vehicleNo) continue;
        [['AM', amIndex], ['PM', pmIndex]].forEach(([shiftType, column]) => {
          if (column < 0) return;
          const driverName = String(row[column] ?? '').trim();
          if (!driverName) return;
          out.push({
            service_date: serviceDate,
            vehicle_no: vehicleNo,
            driver_name: driverName,
            shift_type: shiftType,
            shift_start: null,
            shift_end: null,
            route_no: routeNo,
            run_order: Number.isFinite(runOrder) ? runOrder : -1,
            support_route_no: supportRoute,
            support_run_order: Number.isFinite(supportOrder) ? supportOrder : null,
            source_format: 'ROUTE_ASSIGN', source_sheet: sheetName,
          });
        });
      }
    }
    return out;
  }

  function mergeDispatchRows(rows) {
    const routeBases = new Map();
    rows.filter(row => row.source_format === 'DAILY_ROUTE').forEach(row => {
      routeBases.set([row.service_date, row.vehicle_no, row.shift_type].join('|'), row);
    });
    const merged = new Map();
    for (const sourceRow of rows) {
      if (sourceRow.source_format === 'DAILY_ROUTE' || !sourceRow.driver_name) continue;
      const row = { ...sourceRow };
      const base = routeBases.get([row.service_date, row.vehicle_no, row.shift_type].join('|'));
      if (base) {
        if (!row.shift_start && base.shift_start) row.shift_start = base.shift_start;
        if (!row.route_no && base.route_no) row.route_no = base.route_no;
        if ((!row.run_order || row.run_order < 1) && base.run_order > 0) row.run_order = base.run_order;
        row.source_format = row.source_format === 'DAILY_ROUTE' ? 'DAILY_ROUTE' : 'MERGED';
        row.source_file = [row.source_file, base.source_file].filter(Boolean).join(' + ');
      }
      const key = [row.service_date, row.vehicle_no, row.driver_name, row.shift_type].join('|');
      const existing = merged.get(key);
      if (!existing) { merged.set(key, row); continue; }
      if (!existing.shift_start && row.shift_start) existing.shift_start = row.shift_start;
      if (!existing.shift_end && row.shift_end) existing.shift_end = row.shift_end;
      if ((!existing.route_no || existing.route_no === '-1') && row.route_no) existing.route_no = row.route_no;
      if ((!existing.run_order || existing.run_order < 1) && Number(row.run_order) > 0) existing.run_order = Number(row.run_order);
      if (!existing.support_route_no && row.support_route_no) existing.support_route_no = row.support_route_no;
      if ((existing.support_run_order === null || existing.support_run_order === undefined) && Number(row.support_run_order) > 0) existing.support_run_order = Number(row.support_run_order);
      if (existing.source_format !== row.source_format) existing.source_format = 'MERGED';
      existing.source_file = [...new Set([...(String(existing.source_file || '').split(' + ')), ...(String(row.source_file || '').split(' + '))].filter(Boolean))].join(' + ');
    }
    return [...merged.values()].sort((a, b) => `${a.service_date}|${a.route_no}|${a.run_order}|${a.shift_type}`.localeCompare(`${b.service_date}|${b.route_no}|${b.run_order}|${b.shift_type}`, 'ko'));
  }

  function readWorkbook(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        try {
          const workbook = XLSX.read(reader.result, { type: 'array', cellDates: false });
          resolve(workbook.SheetNames.map(name => ({
            name,
            rows: XLSX.utils.sheet_to_json(workbook.Sheets[name], { header: 1, raw: true, defval: '' }),
          })));
        } catch (error) { reject(error); }
      };
      reader.onerror = reject;
      reader.readAsArrayBuffer(file);
    });
  }

  async function handleDispatchFiles(files) {
    if (typeof XLSX === 'undefined') return toast('SheetJS를 불러오지 못했습니다. 인터넷 연결을 확인하세요.', true);
    if (!files.length) return;
    $('#dispatchPreview').innerHTML = '<div class="card empty">배차표를 분석하고 있습니다.</div>';
    const all = [];
    const fileStatus = [];
    for (const file of files) {
      try {
        const sheets = await readWorkbook(file);
        let count = 0;
        for (const sheet of sheets) {
          const normalized = normalizeDispatch(sheet.rows, file.name, sheet.name);
          count += normalized.length;
          all.push(...normalized.map(row => ({ ...row, source_file: file.name })));
        }
        fileStatus.push({ file: file.name, count, ok: count > 0 });
      } catch (error) {
        fileStatus.push({ file: file.name, count: 0, ok: false, error: error.message });
      }
    }
    if (!all.length) {
      $('#dispatchPreview').innerHTML = `<div class="notice warn">인식 가능한 배차 데이터가 없습니다.<br>${fileStatus.map(item => `${esc(item.file)}: ${esc(item.error || '지원 헤더를 찾지 못함')}`).join('<br>')}</div>`;
      return;
    }
    const merged = mergeDispatchRows(all);
    const dates = [...new Set(merged.map(row => row.service_date))].sort();
    $('#dispatchPreview').innerHTML = `
      <div class="notice"><b>${files.length}개 파일 / ${dates.length}개 운행일</b>에서 원본 ${all.length}건 → 기사 기준 병합 ${merged.length}건을 인식했습니다. 기사 없는 일일 노선자료는 같은 일자·차량·AM/PM 기사자료에 보완됩니다.</div>
      <div class="file-result-grid">${fileStatus.map(item => `<div class="file-result ${item.ok ? 'ok' : 'bad'}"><b>${esc(item.file)}</b><span>${item.ok ? `${item.count}건` : esc(item.error || '인식 실패')}</span></div>`).join('')}</div>
      <div class="date-chips">${dates.map(date => `<span>${date}</span>`).join('')}</div>
      <div class="table-wrap"><table><thead><tr><th>일자</th><th>차량</th><th>기사</th><th>구분</th><th>노선</th><th>순번</th><th>시작</th><th>종료</th><th>원본</th></tr></thead><tbody>
      ${merged.slice(0, 50).map(row => `<tr><td>${row.service_date}</td><td>${esc(row.vehicle_no)}</td><td>${esc(row.driver_name)}</td><td>${row.shift_type}</td><td>${esc(row.route_no)}</td><td>${row.run_order > 0 ? row.run_order : '-'}</td><td>${row.shift_start ? fmtDT(row.shift_start) : '-'}</td><td>${row.shift_end ? fmtDT(row.shift_end) : '-'}</td><td>${esc(row.source_file || '')}</td></tr>`).join('')}
      </tbody></table></div>
      <button id="saveDispatch" class="btn primary" style="margin-top:12px">Supabase에 ${merged.length}건 저장</button>`;

    $('#saveDispatch').onclick = async () => {
      const button = $('#saveDispatch');
      const batchSize = 75;
      let saved = 0;
      try {
        button.disabled = true;
        for (let index = 0; index < merged.length; index += batchSize) {
          const part = merged.slice(index, index + batchSize);
          const sourceFiles = [...new Set(part.map(row => row.source_file).filter(Boolean))].join(', ');
          button.textContent = `저장 중 ${Math.min(index + part.length, merged.length)}/${merged.length}`;
          const result = await rpc('admin_import_dispatch', {
            p_token: token(),
            p_rows: part,
            p_source_file: `${sourceFiles} [${Math.floor(index / batchSize) + 1}/${Math.ceil(merged.length / batchSize)}]`,
          });
          saved += Number(result?.rows || 0);
        }
        toast(`${saved}건을 저장했습니다.`);
        if (dates[0] && $('#dispatchDate')) $('#dispatchDate').value = dates[0];
        button.textContent = `저장 완료 ${saved}건`;
        await loadDispatchList();
      } catch (error) {
        button.disabled = false;
        button.textContent = `다시 저장 (${saved}/${merged.length} 처리)`;
        toast(`${saved}건 처리 후 오류: ${error.message}`, true);
      }
    };
  }

  async function loadDispatchList() {
    const serviceDate = $('#dispatchDate')?.value;
    if (!serviceDate) return;
    const rows = await rpc('admin_list_dispatch', { p_token: token(), p_service_date: serviceDate });
    $('#dispatchList').innerHTML = rows.length ? `<div class="table-wrap"><table><thead><tr><th>차량</th><th>기사</th><th>구분</th><th>노선</th><th>순번</th><th>시작</th><th>종료</th><th>원본</th></tr></thead><tbody>${rows.map(row => `<tr><td>${esc(row.vehicle_no)}</td><td>${esc(row.driver_name)}</td><td>${row.shift_type}</td><td>${esc(row.route_no)}</td><td>${row.run_order > 0 ? row.run_order : '-'}</td><td>${row.shift_start ? fmtDT(row.shift_start) : '-'}</td><td>${row.shift_end ? fmtDT(row.shift_end) : '-'}</td><td>${esc(row.source_file || row.source_format || '')}</td></tr>`).join('')}</tbody></table></div>` : '<div class="card empty">해당 날짜 배차가 없습니다.</div>';
  }


  // ---------- Route timetable multi-file import ----------
  function normalizeRouteNo(value) {
    const text = String(value ?? '').trim();
    const bracket = text.match(/\(([^)]+)\)/);
    if (bracket && /[0-9]/.test(bracket[1])) return bracket[1].replace(/\s/g, '');
    return text.replace(/\s/g, '');
  }

  function normalizeScheduleTime(value) {
    const hhmm = excelTimeToHHMM(value);
    return hhmm ? `${hhmm}:00` : null;
  }

  function scheduleDayType(title) {
    const text = String(title || '');
    if (/토요일/.test(text)) return 'SATURDAY';
    if (/일[,·\s]*공휴일|일요일|공휴일/.test(text)) return 'HOLIDAY';
    return 'WEEKDAY';
  }

  function inferEffectiveDate(filename) {
    const direct = inferDateFromFilename(filename);
    if (direct) return direct;
    const match = String(filename || '').match(/(20\d{2})[.\-_ ]\s*(\d{1,2})[.\-_ ]\s*(\d{1,2})/);
    return match ? `${match[1]}-${String(match[2]).padStart(2, '0')}-${String(match[3]).padStart(2, '0')}` : todayISO();
  }

  function parseTimetableSheet(rows, filename, sheetName, seasonType) {
    if (!rows?.length) return [];
    const first = rows[0] || [];
    const second = rows[1] || [];
    const maxCols = Math.max(first.length, second.length);
    const starts = [];
    for (let col = 0; col < maxCols; col++) {
      if (canonical(second[col]) === canonical('노선번호')) starts.push(col);
    }
    const output = [];
    starts.forEach((startCol, blockIndex) => {
      const endCol = blockIndex + 1 < starts.length ? starts[blockIndex + 1] : maxCols;
      const title = first[startCol] || first[Math.max(0, startCol - 1)] || '';
      const dayType = scheduleDayType(title);
      const orderCols = [];
      for (let col = startCol + 1; col < endCol; col++) {
        if (canonical(second[col]) === canonical('순번')) orderCols.push(col);
      }
      // Each direction is identified by its own 순번 column. The first usable
      // timetable/time column after it becomes the departure reference.
      const directions = orderCols.map((orderCol, index) => {
        const nextOrder = index + 1 < orderCols.length ? orderCols[index + 1] : endCol;
        let timeCol = -1;
        for (let col = orderCol + 1; col < nextOrder; col++) {
          if (String(second[col] ?? '').trim()) { timeCol = col; break; }
        }
        return {
          orderCol,
          timeCol,
          directionName: timeCol >= 0 ? String(second[timeCol] || `방향${index + 1}`).trim() : `방향${index + 1}`,
        };
      }).filter(item => item.timeCol >= 0);

      for (let rowIndex = 2; rowIndex < rows.length; rowIndex++) {
        const row = rows[rowIndex] || [];
        const routeNo = normalizeRouteNo(row[startCol]);
        if (!routeNo) continue;
        directions.forEach(direction => {
          const runOrder = parseInt(row[direction.orderCol], 10);
          const departureTime = normalizeScheduleTime(row[direction.timeCol]);
          if (!Number.isFinite(runOrder) || runOrder < 1 || !departureTime) return;
          output.push({
            route_no: routeNo,
            run_order: runOrder,
            day_type: dayType,
            direction_name: direction.directionName,
            departure_time: departureTime,
            source_sheet: sheetName,
            source_row: rowIndex + 1,
            season_type: seasonType,
          });
        });
      }
    });
    return output;
  }

  async function timetablePage() {
    $('#page').innerHTML = `<div class="card">
      <h3>노선별·운행순위별 운행시간표 업로드</h3>
      <p class="notice">평일·토요일·일/공휴일 시간표가 포함된 Excel을 개별 또는 여러 개 선택할 수 있습니다. 변경 시행일을 기준으로 버전을 보관하며, 방학 시간표는 <b>방학</b> 구분으로 등록합니다.</p>
      <div class="form-grid">
        <label>시간표 구분<select id="ttSeason"><option value="NORMAL">일반</option><option value="VACATION">방학</option><option value="SPECIAL">임시/특별</option></select></label>
        <label>적용 종료일(선택)<input id="ttEndDate" type="date"></label>
      </div>
      <div class="dropzone"><input id="timetableFile" type="file" accept=".xls,.xlsx" multiple><p>노선별 운행시간표 파일을 선택하세요.</p></div>
      <div id="timetablePreview"></div>
    </div>
    <div class="section-title"><h3>등록된 시간표 버전</h3><button id="refreshTimetable" class="btn secondary">새로고침</button></div>
    <div id="timetableHistory"></div>
    <div class="section-title"><h3>공휴일·특수 운행일 지정</h3></div>
    <div class="card"><div class="form-grid">
      <label>적용일<input id="calendarDate" type="date"></label>
      <label>운행일 유형<select id="calendarType"><option value="HOLIDAY">일·공휴일</option><option value="SATURDAY">토요일</option><option value="WEEKDAY">평일</option></select></label>
      <label class="span-2">비고<input id="calendarNote" placeholder="예: 설날, 임시공휴일, 대체공휴일"></label>
    </div><button id="saveCalendar" class="btn primary">운행일 유형 저장</button></div>
    <div id="calendarHistory" style="margin-top:12px"></div>`;
    $('#timetableFile').onchange = () => handleTimetableFiles([...$('#timetableFile').files]);
    $('#refreshTimetable').onclick = async () => { await loadTimetableHistory(); await loadCalendarHistory(); };
    $('#saveCalendar').onclick = saveCalendarOverride;
    await Promise.all([loadTimetableHistory(), loadCalendarHistory()]);
  }

  async function handleTimetableFiles(files) {
    if (!files.length) return;
    if (typeof XLSX === 'undefined') return toast('SheetJS를 불러오지 못했습니다.', true);
    const seasonType = $('#ttSeason').value;
    const effectiveTo = $('#ttEndDate').value || null;
    const packages = [];
    const errors = [];
    for (const file of files) {
      try {
        const sheets = await readWorkbook(file);
        const rows = [];
        for (const sheet of sheets) rows.push(...parseTimetableSheet(sheet.rows, file.name, sheet.name, seasonType));
        if (!rows.length) throw new Error('노선번호/순번/출발시간 구조를 찾지 못했습니다.');
        packages.push({
          file: file.name,
          effective_from: inferEffectiveDate(file.name),
          effective_to: effectiveTo,
          season_type: seasonType,
          rows,
        });
      } catch (error) {
        errors.push(`${file.name}: ${error.message}`);
      }
    }
    $('#timetablePreview').innerHTML = `${errors.length ? `<div class="notice warn">${errors.map(esc).join('<br>')}</div>` : ''}
      ${packages.map((item, index) => `<div class="card">
        <div class="toolbar"><b>${esc(item.file)}</b><span>${item.effective_from}부터 · ${esc(item.season_type)} · ${item.rows.length}건</span></div>
        <div class="date-chips">${[...new Set(item.rows.map(row => row.day_type))].map(type => `<span>${type}</span>`).join('')}</div>
        <button class="btn primary save-timetable" data-index="${index}">시간표 저장</button>
      </div>`).join('')}`;
    $$('.save-timetable').forEach(button => {
      button.onclick = async () => {
        const item = packages[Number(button.dataset.index)];
        try {
          button.disabled = true;
          const result = await rpc('admin_import_timetable', {
            p_token: token(),
            p_meta: {
              version_name: item.file,
              effective_from: item.effective_from,
              effective_to: item.effective_to,
              season_type: item.season_type,
              source_file: item.file,
            },
            p_rows: item.rows,
          });
          button.textContent = `저장 완료 ${result?.rows || item.rows.length}건`;
          toast(`${item.file} 시간표를 저장했습니다.`);
          await loadTimetableHistory();
        } catch (error) {
          button.disabled = false;
          toast(error.message, true);
        }
      };
    });
  }

  async function loadTimetableHistory() {
    const rows = await rpc('admin_list_timetable_versions', { p_token: token(), p_limit: 100 });
    $('#timetableHistory').innerHTML = rows?.length ? `<div class="table-wrap"><table><thead><tr><th>버전</th><th>구분</th><th>적용기간</th><th>슬롯수</th><th>원본파일</th><th>등록시각</th></tr></thead><tbody>${rows.map(row => `<tr><td><b>${esc(row.version_name)}</b></td><td>${esc(row.season_type)}</td><td>${row.effective_from} ~ ${row.effective_to || '계속'}</td><td>${row.slot_count}</td><td>${esc(row.source_file || '')}</td><td>${fmtDT(row.imported_at)}</td></tr>`).join('')}</tbody></table></div>` : '<div class="card empty">등록된 운행시간표가 없습니다.</div>';
  }


  async function saveCalendarOverride() {
    const serviceDate = $('#calendarDate').value;
    if (!serviceDate) return toast('적용일을 선택하세요.', true);
    try {
      await rpc('admin_upsert_service_calendar', {
        p_token: token(),
        p_service_date: serviceDate,
        p_day_type: $('#calendarType').value,
        p_note: $('#calendarNote').value.trim() || null,
      });
      toast('운행일 유형을 저장했습니다.');
      await loadCalendarHistory();
    } catch (error) { toast(error.message, true); }
  }

  async function loadCalendarHistory() {
    const from = new Date(); from.setDate(from.getDate() - 30);
    const to = new Date(); to.setFullYear(to.getFullYear() + 1);
    const rows = await rpc('admin_list_service_calendar', {
      p_token: token(), p_from: from.toISOString().slice(0, 10), p_to: to.toISOString().slice(0, 10),
    });
    const labels = { WEEKDAY: '평일', SATURDAY: '토요일', HOLIDAY: '일·공휴일' };
    $('#calendarHistory').innerHTML = rows?.length ? `<div class="table-wrap"><table><thead><tr><th>일자</th><th>적용 시간표</th><th>비고</th><th>수정시각</th></tr></thead><tbody>${rows.map(row => `<tr><td>${row.service_date}</td><td>${esc(labels[row.day_type] || row.day_type)}</td><td>${esc(row.note || '')}</td><td>${fmtDT(row.updated_at)}</td></tr>`).join('')}</tbody></table></div>` : '<div class="card empty">별도 지정된 공휴일·특수 운행일이 없습니다.</div>';
  }



  // ---------- Admin driver analysis ----------
  async function reportsPage() {
    $('#page').innerHTML = `<div class="card">
      <div class="toolbar">
        <label>기사 선택<select id="reportDriver"><option value="">전체 기사</option></select></label>
        <label>시작일<input id="reportFrom" type="date"></label>
        <label>종료일<input id="reportTo" type="date"></label>
        <button id="loadReports" class="btn primary">조회</button>
      </div>
      <p class="notice"><b>SafeDrive 자체 운행분석</b>입니다. 교통안전공단 보고서의 시각적 구성과 위험운전 항목을 참고하되, CDT 1초 데이터와 회사 기준으로 산출하므로 공단 공식점수와 구분합니다.</p>
    </div><div id="reportContent"></div>`;
    const initial = await rpc('admin_driver_reports', { p_token: token(), p_driver_name: null, p_from: null, p_to: null, p_limit: 500 });
    $('#reportDriver').innerHTML += (initial.drivers || []).map(driver => `<option value="${esc(driver.display_name)}">${esc(driver.display_name)}</option>`).join('');
    $('#loadReports').onclick = loadDriverReports;
    renderDriverReports(initial);
  }

  async function loadDriverReports() {
    const name = $('#reportDriver').value;
    const data = await rpc('admin_driver_reports', {
      p_token: token(),
      p_driver_name: name || null,
      p_from: $('#reportFrom').value || null,
      p_to: $('#reportTo').value || null,
      p_limit: 500,
    });
    renderDriverReports(data);
  }

  function analysisCard(report) {
    const distance = num(report.distance_km);
    const rate = key => distance > 0 ? (num(report[key]) * 100 / distance).toFixed(2) : '0.00';
    const recommendations = Array.isArray(report.recommendations) ? report.recommendations : [];
    return `<article class="report-card analysis-card">
      <div class="report-head"><div><b>${esc(report.driver_name)}</b><small>${esc(report.service_date)} · ${esc(report.route_no || '전체노선')} · ${esc(report.vehicle_no || '')}</small></div>${badge(report.safety_level || '-')}</div>
      <div class="score-wrap"><div class="score-ring"><strong>${report.safety_score ?? '-'}</strong><span>SafeDrive 점수</span></div>
      <div class="analysis-summary"><p>${esc(report.analysis_text || '분석내용 없음')}</p><small>운행거리 ${distance.toFixed(1)}km · 최고속도 ${num(report.max_speed)}km/h · 수집지연 ${report.late_days || 0}일 · 매칭 ${esc(report.match_status || report.data_quality || '-')}</small></div></div>
      <div class="behavior-grid">
        <div class="behavior-item"><span>급출발</span><b>${report.rapid_start || 0}</b><small>${rate('rapid_start')}/100km</small></div>
        <div class="behavior-item"><span>급가속</span><b>${report.rapid_accel || 0}</b><small>${rate('rapid_accel')}/100km</small></div>
        <div class="behavior-item"><span>급감속</span><b>${report.rapid_decel || 0}</b><small>${rate('rapid_decel')}/100km</small></div>
        <div class="behavior-item"><span>급정지</span><b>${report.rapid_stop || 0}</b><small>${rate('rapid_stop')}/100km</small></div>
        <div class="behavior-item"><span>관리속도 초과</span><b>${report.speed_watch || 0}</b><small>${rate('speed_watch')}/100km</small></div>
      </div>
      ${recommendations.length ? `<ul class="recommend-list">${recommendations.map(item => `<li>${esc(item)}</li>`).join('')}</ul>` : ''}
      <div class="report-foot">기사 확인: ${report.acknowledged_at ? `<span class="ack-ok">${fmtDT(report.acknowledged_at)}</span>` : '<span class="ack-wait">미확인</span>'}</div>
    </article>`;
  }

  function renderDriverReports(data) {
    const daily = data.daily || [];
    const monthly = data.monthly || [];
    const pending = data.pending || [];
    $('#reportContent').innerHTML = `
      <div class="grid cols-4">
        <div class="card metric"><span class="label">분석 건수</span><span class="value">${daily.length}</span></div>
        <div class="card metric good"><span class="label">평균점수</span><span class="value">${daily.length ? (daily.reduce((a,b)=>a+num(b.safety_score),0)/daily.length).toFixed(1) : '-'}</span></div>
        <div class="card metric warn"><span class="label">지연수집/부분매칭</span><span class="value">${pending.length}</span></div>
        <div class="card metric"><span class="label">월간집계</span><span class="value">${monthly.length}</span></div>
      </div>
      ${pending.length ? `<div class="notice warn"><b>배차/BIS 매칭 대기 또는 부분매칭 자료 ${pending.length}건</b><br>CDT는 차량 입고 후 며칠 뒤 수집될 수 있으며, 운행일 기준 자료가 보완되면 Collector가 자동 재분석합니다.</div>` : ''}
      <div class="section-title"><h3>기사별 일일 운행분석</h3><span>${daily.length}건</span></div>
      ${daily.length ? `<div class="report-card-grid">${daily.map(analysisCard).join('')}</div>` : '<div class="card empty">분석자료가 없습니다.</div>'}
      <div class="section-title"><h3>월간 추이</h3></div>
      ${monthly.length ? `<div class="table-wrap"><table><thead><tr><th>기사</th><th>분석월</th><th>운행일</th><th>거리</th><th>평균점수</th><th>급출발</th><th>급가속</th><th>급감속</th><th>급정지</th><th>과속후보</th></tr></thead><tbody>${monthly.map(row => `<tr><td><b>${esc(row.driver_name)}</b></td><td>${esc(row.analysis_month)}</td><td>${row.days_count}</td><td>${num(row.distance_km).toFixed(1)}km</td><td>${num(row.avg_score).toFixed(1)}</td><td>${row.rapid_start}</td><td>${row.rapid_accel}</td><td>${row.rapid_decel}</td><td>${row.rapid_stop}</td><td>${row.speed_watch}</td></tr>`).join('')}</tbody></table></div>` : '<div class="card empty">월간집계가 없습니다.</div>'}`;
  }

  // ---------- BIS changes ----------
  async function changesPage() {
    const today = todayISO();
    $('#page').innerHTML = `<div class="card"><h3>BIS 차량변경 실시간 감시</h3><p class="notice">Collector가 배차표 예정차량과 TAGO 실시간 운행차량을 ${30}초 단위로 비교합니다. 전체 위치는 저장하지 않고, 반복 확인된 차량변경 이벤트만 Supabase에 저장합니다.</p><div class="toolbar"><input id="changeDate" type="date" value="${today}"><button id="loadChanges" class="btn secondary">조회</button></div><div id="bisStatus"></div></div><div class="section-title"><h3>차량변경 이력</h3></div><div id="changeList"></div>`;
    $('#loadChanges').onclick = loadChanges;
    await loadChanges();
  }

  async function loadChanges() {
    const serviceDate = $('#changeDate').value;
    const [dashboard, status] = await Promise.all([
      rpc('admin_dashboard', { p_token: token(), p_service_date: serviceDate }),
      rpc('admin_collector_status', { p_token: token(), p_limit: 10 }).catch(() => ({ agents: [] })),
    ]);
    const agent = status.agents?.[0];
    const summary = agent?.counters?.last_bis_summary || {};
    $('#bisStatus').innerHTML = `<div class="grid cols-4 compact-metrics"><div class="card metric"><span class="label">마지막 BIS 조회</span><span class="value mini">${agent?.last_bis_poll_at ? fmtDT(agent.last_bis_poll_at) : '-'}</span></div><div class="card metric"><span class="label">조회 노선</span><span class="value">${summary.routes ?? '-'}</span></div><div class="card metric warn"><span class="label">불일치 후보</span><span class="value">${summary.mismatches ?? '-'}</span></div><div class="card metric ${agent?.online ? 'good' : 'bad'}"><span class="label">Collector</span><span class="value mini">${agent?.online ? 'ONLINE' : 'OFFLINE'}</span></div></div>`;
    $('#changeList').innerHTML = tableChanges(dashboard.changes || []);
  }


  // ---------- Collector status ----------
  async function collectorPage() {
    $('#page').innerHTML = `<div class="card"><h3>자료수집 구조</h3>
      <div class="source-flow"><div><b>일일 배차표</b><span>기사·예정차량</span></div><i>+</i><div><b>운행시간표</b><span>노선·운행순위·시간</span></div><i>+</i><div><b>BIS/TAGO</b><span>실제 운행차량 확인</span></div><i>→</i><div><b>CDT/TACO</b><span>입고 시 자동 분석</span></div></div>
      <p class="notice"><b>CDT는 차량 입고·수리 일정에 따라 며칠 뒤 수집될 수 있습니다.</b> Collector는 파일의 실제 운행일을 읽어 과거 배차·BIS 차량변경 자료와 다시 연결합니다. Supabase에는 원본 CDT나 전체 BIS 위치를 저장하지 않고, 파일 메타정보·차량변경·기사별 집계·대표 이벤트만 저장합니다.</p>
      <p class="small muted">Collector 제어센터를 닫아도 Windows 백그라운드 예약작업은 계속 실행됩니다. 설정·처리상태 파일은 업데이트 시 삭제하거나 초기화하지 않습니다.</p>
    </div><div id="collectorContent"></div>`;
    await loadCollectorStatus();
    state.refreshTimer = setInterval(() => {
      if (state.page === 'collector') loadCollectorStatus(true).catch(() => {});
    }, 15000);
  }

  async function loadCollectorStatus(silent = false) {
    const data = await rpc('admin_collector_status', { p_token: token(), p_limit: 100 });
    const agents = data.agents || [];
    const activities = data.activities || [];
    $('#collectorContent').innerHTML = `
      <div class="section-title"><h3>Collector 상태</h3><button id="refreshCollector" class="btn secondary">새로고침</button></div>
      ${agents.length ? agents.map(agent => `<div class="card collector-agent"><div class="agent-head"><div><b>${esc(agent.agent_id)}</b><small>${esc(agent.host_name || '')} · ${esc(agent.version || '')}</small></div>${badge(agent.online ? 'ONLINE' : agent.status || 'OFFLINE')}</div>
      <div class="grid cols-4 compact-metrics"><div class="metric"><span class="label">마지막 Heartbeat</span><span class="value mini">${fmtDT(agent.last_heartbeat_at)}</span></div><div class="metric"><span class="label">CDT 검색</span><span class="value mini">${agent.last_taco_scan_at ? fmtDT(agent.last_taco_scan_at) : '-'}</span></div><div class="metric"><span class="label">BIS 조회</span><span class="value mini">${agent.last_bis_poll_at ? fmtDT(agent.last_bis_poll_at) : '-'}</span></div><div class="metric"><span class="label">매칭 대기</span><span class="value">${agent.counters?.pending_cdt || 0}</span></div></div>
      <div class="agent-counters">CDT 처리 ${agent.counters?.taco_files || 0}파일 · 대표이벤트 ${agent.counters?.taco_events || 0}건 · BIS 조회 ${agent.counters?.bis_polls || 0}회 · 실제차량 연결 ${agent.counters?.bis_changes || 0}건</div>
      ${agent.last_error ? `<div class="notice warn">최근 오류: ${esc(agent.last_error)}</div>` : ''}
      <div class="toolbar"><button class="btn secondary collector-command" data-agent="${esc(agent.agent_id)}" data-command="reload">설정 재읽기</button><button class="btn secondary collector-command" data-agent="${esc(agent.agent_id)}" data-command="restart">재시작 요청</button><button class="btn danger collector-command" data-agent="${esc(agent.agent_id)}" data-command="stop">종료 요청</button></div></div>`).join('') : '<div class="card empty">등록된 Collector가 없습니다. 회사 PC에서 백그라운드 Collector를 설치·실행하세요.</div>'}
      <div class="section-title"><h3>최근 수집 활동</h3></div>
      ${activities.length ? `<div class="table-wrap"><table><thead><tr><th>시각</th><th>Agent</th><th>구분</th><th>수준</th><th>내용</th></tr></thead><tbody>${activities.map(item => `<tr><td>${fmtDT(item.created_at)}</td><td>${esc(item.agent_id || '-')}</td><td>${esc(item.category)}</td><td>${badge(item.level)}</td><td>${esc(item.message)}</td></tr>`).join('')}</tbody></table></div>` : '<div class="card empty">활동내역이 없습니다.</div>'}
      <div class="section-title"><h3>최근 CDT 수집·매칭 상태</h3></div>${tableImports(data.taco_recent || [])}`;
    $('#refreshCollector').onclick = () => loadCollectorStatus();
    $$('.collector-command').forEach(button => {
      button.onclick = async () => {
        const command = button.dataset.command;
        if (!confirm(`Collector에 ${command} 요청을 보낼까요? 수집 설정과 처리이력은 초기화되지 않습니다.`)) return;
        try {
          await rpc('admin_collector_command', { p_token: token(), p_agent_id: button.dataset.agent, p_command: command });
          toast('명령을 등록했습니다.');
          setTimeout(() => loadCollectorStatus(true), 2000);
        } catch (error) { toast(error.message, true); }
      };
    });
    if (!silent) toast('수집현황을 불러왔습니다.');
  }

  async function driversPage() {
    const rows = await rpc('admin_list_users', { p_token: token() });
    $('#page').innerHTML = `<div class="notice">일일 배차표 업로드 시 기사 이름으로 계정이 자동 생성됩니다. 초기 비밀번호는 1111이며 첫 로그인 후 변경이 강제됩니다.</div><div class="section-title"><h3>사용자</h3></div><div class="table-wrap"><table><thead><tr><th>ID</th><th>이름</th><th>역할</th><th>비밀번호변경</th><th>최근로그인</th><th></th></tr></thead><tbody>${rows.map(row => `<tr><td>${esc(row.login_id)}</td><td><b>${esc(row.display_name)}</b></td><td>${row.role}</td><td>${row.must_change_password ? '필요' : '완료'}</td><td>${row.last_login_at ? fmtDT(row.last_login_at) : '-'}</td><td>${row.role === 'driver' ? `<button class="btn danger resetpw" data-id="${row.id}">1111로 초기화</button>` : ''}</td></tr>`).join('')}</tbody></table></div>`;
    $$('.resetpw').forEach(button => button.onclick = async () => {
      if (!confirm('비밀번호를 1111로 초기화할까요?')) return;
      try { await rpc('admin_reset_password', { p_token: token(), p_user_id: button.dataset.id }); toast('초기화했습니다.'); driversPage(); } catch (error) { toast(error.message, true); }
    });
  }

  async function ackPage() {
    const rows = await rpc('admin_ack_status', { p_token: token(), p_limit: 500 });
    $('#page').innerHTML = `<div class="notice">기사가 본인의 분석결과에서 <b>확인했습니다</b>를 누른 시각을 관리합니다.</div><div class="section-title"><h3>확인현황</h3></div><div class="table-wrap"><table><thead><tr><th>기사</th><th>기간</th><th>자료</th><th>공개일</th><th>확인여부</th><th>확인시각</th></tr></thead><tbody>${rows.map(row => `<tr><td><b>${esc(row.driver_name)}</b></td><td>${row.period_start} ~ ${row.period_end}</td><td>${esc(row.title)}</td><td>${fmtDT(row.published_at)}</td><td>${row.acknowledged_at ? '<span class="ack-ok">확인</span>' : '<span class="ack-wait">미확인</span>'}</td><td>${row.acknowledged_at ? fmtDT(row.acknowledged_at) : '-'}</td></tr>`).join('')}</tbody></table></div>`;
  }

  async function auditPage() {
    const rows = await rpc('admin_audit', { p_token: token(), p_limit: 500 });
    $('#page').innerHTML = `<div class="table-wrap"><table><thead><tr><th>시각</th><th>작업자</th><th>행위</th><th>대상</th><th>상세</th></tr></thead><tbody>${rows.map(row => `<tr><td>${fmtDT(row.created_at)}</td><td>${esc(row.user_name)}</td><td>${esc(row.action)}</td><td>${esc(row.entity_type || '')} ${esc(row.entity_id || '')}</td><td>${esc(JSON.stringify(row.detail || {}))}</td></tr>`).join('')}</tbody></table></div>`;
  }

  async function driverDashboard() {
    const data = await rpc('driver_dashboard', { p_token: token(), p_limit: 30 });
    const latest = data.daily?.[0];
    const publication = data.publications?.[0];
    $('#page').innerHTML = `<div class="card driver-hero"><span class="kicker">MY SAFE DRIVE</span><h2>${esc(state.session.display_name)} 기사님</h2><div class="grid cols-3">
      <div class="metric"><span class="label muted">최근 SafeDrive 점수</span><span class="level">${latest?.safety_score ?? '자료 없음'}</span></div>
      <div class="metric"><span class="label muted">최근 안전수준</span><span class="level">${esc(latest?.safety_level || '-')}</span></div>
      <div class="metric"><span class="label muted">분석결과 확인</span><span class="level">${publication ? (publication.acknowledged ? '완료' : '미확인') : '-'}</span></div></div></div>
      <div class="notice">SafeDrive 결과는 CDT 운행기록과 배차·BIS 실제차량 연결자료를 이용한 회사 자체 분석입니다. 교통안전공단 공식점수와 구분되며 안전운전 개선과 피드백을 목적으로 합니다.</div>
      <div class="section-title"><h3>나에게 공개된 운행분석</h3></div>${renderPublications(data.publications)}
      <div class="section-title"><h3>최근 일일 운행분석</h3></div>${tableTaco(data.daily || [])}`;
    $$('.ackbtn').forEach(button => button.onclick = async () => {
      try { await rpc('driver_acknowledge', { p_token: token(), p_publication_id: Number(button.dataset.id), p_comment: null }); toast('확인 처리했습니다.'); driverDashboard(); } catch (error) { toast(error.message, true); }
    });
  }

  function flattenRecommendations(value) {
    const output = [];
    const visit = item => {
      if (Array.isArray(item)) item.forEach(visit);
      else if (item !== null && item !== undefined && String(item).trim()) output.push(String(item));
    };
    visit(value);
    return [...new Set(output)];
  }

  function renderPublications(rows) {
    if (!rows?.length) return '<div class="card empty">공개된 분석자료가 없습니다.</div>';
    return rows.map(publication => { const recs = flattenRecommendations(publication.summary?.recommendations); return `<div class="pub-card"><div class="pub-head"><div><b>${esc(publication.title)}</b><div class="small muted">${publication.period_start} ~ ${publication.period_end} · ${esc(publication.source)}</div></div><div>${publication.acknowledged ? '<span class="badge good">확인완료</span>' : `<button class="btn primary ackbtn" data-id="${publication.id}">확인했습니다</button>`}</div></div><p>${esc(publication.summary?.summary_text || '')}</p>${['CDT','SAFEDRIVE'].includes(publication.source) ? `<div class="small muted" style="margin-bottom:10px">운행거리 ${num(publication.summary.distance_km).toFixed(1)}km · 차량 ${(publication.summary.vehicles || []).map(esc).join(', ') || '-'} · 노선 ${(publication.summary.routes || []).map(esc).join(', ') || '-'} · 데이터품질 ${esc(publication.summary.data_quality || '-')}</div><div class="behavior-grid"><div class="behavior-item"><span>급출발 후보</span><b>${publication.summary.rapid_start || 0}</b></div><div class="behavior-item"><span>급가속 후보</span><b>${publication.summary.rapid_accel || 0}</b></div><div class="behavior-item"><span>급감속 후보</span><b>${publication.summary.rapid_decel || 0}</b></div><div class="behavior-item"><span>급정지 후보</span><b>${publication.summary.rapid_stop || 0}</b></div><div class="behavior-item"><span>관리속도 초과 후보</span><b>${publication.summary.speed_watch || 0}</b></div></div>${recs.length ? `<ul class="recommend-list">${recs.map(item => `<li>${esc(item)}</li>`).join('')}</ul>` : ''}` : ''}</div>`; }).join('');
  }

  async function driverHistory() {
    const data = await rpc('driver_dashboard', { p_token: token(), p_limit: 100 });
    $('#page').innerHTML = `<div class="section-title"><h3>배차·운행이력</h3></div>${data.dispatch?.length ? `<div class="table-wrap"><table><thead><tr><th>일자</th><th>차량</th><th>노선</th><th>순번</th><th>근무</th></tr></thead><tbody>${data.dispatch.map(row => `<tr><td>${row.service_date}</td><td>${esc(row.vehicle_no)}</td><td>${esc(row.route_no)}</td><td>${row.run_order > 0 ? row.run_order : '-'}</td><td>${row.shift_start ? fmtDT(row.shift_start) : row.shift_type}</td></tr>`).join('')}</tbody></table></div>` : '<div class="card empty">배차 이력이 없습니다.</div>'}<div class="section-title"><h3>차량교체 이력</h3></div>${tableChanges(data.vehicle_changes || [])}`;
  }

  function settingsPage() {
    $('#page').innerHTML = `<div class="grid cols-2">
      <div class="card"><h3>비밀번호 변경</h3><div class="form-grid"><label>현재 비밀번호<input id="spOld" type="password"></label><label>새 비밀번호<input id="spNew" type="password"></label></div><button id="spBtn" class="btn primary">변경</button></div>
      ${state.session.role === 'admin' ? `<div class="card"><h3>Supabase 연결</h3><p class="small muted">관리자 설치 단계에서만 등록합니다. 기사 계정에는 이 메뉴가 표시되지 않습니다.</p><label>URL<input id="cfgUrl" value="${esc(state.cfg.url)}"></label><label>anon/publishable key<textarea id="cfgKey" rows="3">${esc(state.cfg.key)}</textarea></label><div class="toolbar"><button id="cfgBtn" class="btn secondary">현재 브라우저 저장</button><button id="cfgDownloadBtn" class="btn primary">배포용 config.js 생성</button></div><p class="small muted">생성한 config.js를 웹앱 루트에 1회 배포하면 기사 휴대전화에서는 URL/key 입력 없이 로그인합니다. 업데이트 ZIP은 config.js를 제외하여 운영값을 보존합니다.</p></div>
      <div class="card span-2"><h3>백그라운드 Collector</h3><ol class="install-steps"><li><code>collector/setup_windows.bat</code> 실행 - 기존 설정과 처리상태 보존</li><li><code>install_autostart_task.bat</code>를 관리자 권한으로 실행</li><li><code>collector_control.bat</code>에서 시작·종료·상태 확인</li></ol><div class="code-note">CDT 자동수집: E:\\Choyoung\\ADTviewer\\Data (입고·수리로 며칠 늦게 들어와도 운행일 기준 재매칭)<br>BIS: 국토교통부 TAGO 실시간 조회 - 전체 위치는 미저장<br>Supabase: 배차·시간표·차량변경·기사별 집계·대표 이벤트만 저장<br>Collector 제어창을 닫아도 수집은 계속되며 설정/처리이력은 리셋되지 않음</div></div>` : ''}</div>`;
    $('#spBtn').onclick = async () => {
      try { await rpc('app_change_password', { p_token: token(), p_old_password: $('#spOld').value, p_new_password: $('#spNew').value }); toast('비밀번호를 변경했습니다.'); } catch (error) { toast(error.message, true); }
    };
    if ($('#cfgBtn')) $('#cfgBtn').onclick = () => { saveCfg($('#cfgUrl').value.trim(), $('#cfgKey').value.trim()); toast('현재 브라우저에 저장했습니다.'); };
    if ($('#cfgDownloadBtn')) $('#cfgDownloadBtn').onclick = () => {
      const url = $('#cfgUrl').value.trim();
      const key = $('#cfgKey').value.trim();
      if (!url || !key) return toast('URL과 key를 입력하세요.', true);
      downloadConfigJs(url, key);
      toast('config.js를 생성했습니다. GitHub/Netlify 루트에 배포하세요.');
    };
  }

  init();
})();
