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
    const saved = JSON.parse(localStorage.getItem('daewoon_supabase') || '{}');
    state.cfg = {
      url: String(saved.url || '').replace(/\/$/, ''),
      key: saved.key || '',
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
    toast('Supabase 연결정보를 저장했습니다.');
    show('loginView');
  };
  $('#openSetupBtn').onclick = () => {
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
      ['dispatch', '▤ 배차표 관리'],
      ['etas', '▧ eTAS 리포트'],
      ['reports', '◫ 기사별 리포트'],
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
      dispatch: '배차표 관리',
      etas: '교통안전공단 eTAS 리포트',
      reports: '기사별 통합 리포트',
      changes: 'BIS 차량변경',
      collector: '자료수집·Collector 현황',
      drivers: '기사 계정',
      acks: '분석결과 확인현황',
      audit: '작업 이력',
      history: '나의 운행이력',
      settings: '설정',
    };
    $('#pageTitle').textContent = titles[page] || page;
    $('#pageSubtitle').textContent = '대운교통 SafeDrive AI · 배차 / CDT(TACO) / BIS / eTAS 통합';
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
      if (page === 'etas') return etasPage();
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
    if (!rows?.length) return '<div class="card empty">차량변경 기록이 없습니다.</div>';
    return `<div class="table-wrap"><table><thead><tr>
      <th>감지시각</th><th>노선</th><th>순번</th><th>기사</th><th>배차차량</th><th>실제차량</th><th>확인횟수</th><th>신뢰도</th>
      </tr></thead><tbody>${rows.map(row => `<tr>
      <td>${fmtDT(row.detected_at)}</td><td>${esc(row.route_no)}</td><td>${row.run_order > 0 ? row.run_order : '-'}</td>
      <td>${esc(row.driver_name)}</td><td>${esc(row.old_vehicle)}</td><td><b>${esc(row.new_vehicle)}</b></td>
      <td>${row.confirmed_polls || '-'}</td><td>${badge(row.confidence)}</td></tr>`).join('')}</tbody></table></div>`;
  }

  function tableTaco(rows) {
    if (!rows?.length) return '<div class="card empty">분석된 CDT 자료가 없습니다.</div>';
    return `<div class="table-wrap"><table><thead><tr>
      <th>일자</th><th>기사</th><th>차량</th><th>노선</th><th>거리</th><th>최고속도</th><th>급출발</th><th>급가속</th><th>급감속</th><th>급정지</th><th>관리속도</th><th>확인</th>
      </tr></thead><tbody>${rows.map(row => `<tr>
      <td>${esc(row.service_date || '')}</td><td><b>${esc(row.driver_name)}</b></td><td>${esc(row.vehicle_no)}</td><td>${esc(row.route_no)}</td>
      <td>${num(row.distance_km).toFixed(1)}km</td><td>${num(row.max_speed)}</td><td>${row.rapid_start}</td><td>${row.rapid_accel}</td>
      <td>${row.rapid_decel}</td><td>${row.rapid_stop}</td><td>${row.speed_watch}</td>
      <td>${row.acknowledged_at ? '<span class="ack-ok">확인</span>' : '<span class="ack-wait">미확인</span>'}</td></tr>`).join('')}</tbody></table></div>`;
  }

  function tableImports(rows) {
    if (!rows?.length) return '<div class="card empty">수집 이력이 없습니다.</div>';
    return `<div class="table-wrap"><table><thead><tr><th>수집시각</th><th>파일</th><th>차량</th><th>운행일</th><th>레코드</th><th>Agent</th><th>파서</th></tr></thead><tbody>${rows.map(row => `<tr>
      <td>${fmtDT(row.imported_at)}</td><td>${esc(row.source_file)}</td><td>${esc(row.vehicle_no)}</td><td>${esc(row.service_date)}</td>
      <td>${row.record_count}</td><td>${esc(row.collector_agent_id || '-')}</td><td>${esc(row.parser_version)}</td></tr>`).join('')}</tbody></table></div>`;
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
      ${agent ? `<div class="card status-strip"><b>${esc(agent.agent_id)}</b><span>마지막 연결 ${fmtDT(agent.last_heartbeat_at)}</span><span>CDT ${fmtDT(agent.last_taco_scan_at) || '-'}</span><span>BIS ${fmtDT(agent.last_bis_poll_at) || '-'}</span><span>eTAS ${fmtDT(agent.last_etas_scan_at) || '-'}</span></div>` : ''}
      <div class="section-title"><h3>오늘 차량변경</h3><button class="btn secondary" onclick="window.appGo('changes')">전체보기</button></div>
      ${tableChanges(dashboard.changes)}
      <div class="section-title"><h3>오늘 CDT 후보 이벤트 요약</h3><button class="btn secondary" onclick="window.appGo('reports')">기사별 보기</button></div>
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
      <div class="dropzone" id="dispatchDrop"><input id="dispatchFile" type="file" accept=".xls,.xlsx,.csv" multiple><p>여러 배차표 파일을 선택하거나 이 영역에 끌어놓으세요.</p></div>
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
      if (vehicle >= 0 && driver >= 0) return { index, type: 'WORK_TIME', header };
      if (vehicle >= 0 && route >= 0 && (amDriver >= 0 || pmDriver >= 0)) return { index, type: 'ROUTE_ASSIGN', header };
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
    const merged = new Map();
    for (const row of rows) {
      const key = [row.service_date, row.vehicle_no, row.driver_name, row.shift_type].join('|');
      const existing = merged.get(key);
      if (!existing) { merged.set(key, { ...row }); continue; }
      if (!existing.shift_start && row.shift_start) existing.shift_start = row.shift_start;
      if (!existing.shift_end && row.shift_end) existing.shift_end = row.shift_end;
      if ((!existing.route_no || existing.route_no === '-1') && row.route_no) existing.route_no = row.route_no;
      if ((!existing.run_order || existing.run_order < 1) && Number(row.run_order) > 0) existing.run_order = Number(row.run_order);
      if (!existing.support_route_no && row.support_route_no) existing.support_route_no = row.support_route_no;
      if ((existing.support_run_order === null || existing.support_run_order === undefined) && Number(row.support_run_order) > 0) existing.support_run_order = Number(row.support_run_order);
      if (existing.source_format !== row.source_format) existing.source_format = 'MERGED';
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
      <div class="notice"><b>${files.length}개 파일 / ${dates.length}개 운행일</b>에서 원본 ${all.length}건 → 병합 ${merged.length}건을 인식했습니다.</div>
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

  // ---------- eTAS manual + automatic history ----------
  async function etasPage() {
    $('#page').innerHTML = `<div class="card">
      <h3>교통안전공단 eTAS 공식 리포트</h3>
      <div class="notice"><b>CDT(TACO) 자동수집과 eTAS 리포트는 서로 다른 자료입니다.</b><br>
      CDT는 <code>E:\\Choyoung\\ADTviewer\\Data</code>에서 실시간 자동수집됩니다. eTAS는 교통안전공단에서 내려받은 월간 Excel 보고서이므로, 설정된 <b>eTAS 감시폴더</b>에 파일이 생성되면 Collector가 자동 업로드하며 필요 시 여기서도 수동 업로드할 수 있습니다.</div>
      <div class="dropzone"><input id="etasFile" type="file" accept=".xls,.xlsx" multiple><p>eTAS 리포트 여러 개를 선택하여 수동 등록</p></div>
      <div id="etasPreview"></div>
    </div>
    <div class="section-title"><h3>eTAS 등록 내역</h3><button id="refreshEtas" class="btn secondary">새로고침</button></div><div id="etasHistory"></div>`;
    $('#etasFile').onchange = () => handleEtasFiles([...$('#etasFile').files]);
    $('#refreshEtas').onclick = loadEtasHistory;
    await loadEtasHistory();
  }

  async function handleEtasFiles(files) {
    if (!files.length) return;
    if (typeof XLSX === 'undefined') return toast('SheetJS를 불러오지 못했습니다.', true);
    const parsed = [];
    const errors = [];
    for (const file of files) {
      try {
        const sheets = await readWorkbook(file);
        let report = null;
        for (const sheet of sheets) {
          const candidate = parseEtas(sheet.rows, file.name);
          if (candidate.driver_name) { report = candidate; break; }
        }
        if (!report) throw new Error('운전자명을 찾지 못했습니다.');
        report.import_source = 'manual';
        parsed.push(report);
      } catch (error) { errors.push(`${file.name}: ${error.message}`); }
    }
    $('#etasPreview').innerHTML = `${errors.length ? `<div class="notice warn">${errors.map(esc).join('<br>')}</div>` : ''}
      ${parsed.map((report, index) => `<div class="card etas-preview"><div class="grid cols-3"><div class="metric"><span class="label">운전자</span><span class="value small-value">${esc(report.driver_name)}</span></div><div class="metric good"><span class="label">안전수준</span><span class="value small-value">${esc(report.safety_level || '-')}</span></div><div class="metric"><span class="label">분석월 / 점수</span><span class="value small-value">${report.analysis_month.slice(0, 7)} / ${report.total_score ?? '-'}</span></div></div><button class="btn primary save-etas" data-index="${index}">저장·기사 공개</button></div>`).join('')}`;
    $$('.save-etas').forEach(button => {
      button.onclick = async () => {
        const report = parsed[Number(button.dataset.index)];
        try {
          button.disabled = true;
          await rpc('admin_import_etas', { p_token: token(), p_report: report });
          button.textContent = '저장 완료';
          toast(`${report.driver_name} 리포트를 저장했습니다.`);
          await loadEtasHistory();
        } catch (error) { button.disabled = false; toast(error.message, true); }
      };
    });
  }

  function parseEtas(rows, filename) {
    const flat = rows.flat().map(value => String(value ?? '')).filter(Boolean);
    let driver = '', level = '', month = '', summary = '', weekday = '', time = '', trend = '';
    for (const text of flat) {
      let match = text.match(/(.+?)님의 안전운전 수준은\s*["“]?([^"”]+)["”]?/);
      if (match) { driver = match[1].trim(); level = match[2].replace(/[.]/g, '').trim(); }
      match = text.match(/(20\d{2})년\s*(\d{1,2})월/);
      if (match && !month) month = `${match[1]}-${String(match[2]).padStart(2, '0')}-01`;
      if (text.includes('안전운전수준은 업종평균대비')) summary = text.replace(/^⊙\s*/, '');
      if (text.includes('위험운전행동은 특히')) {
        weekday = text.replace(/^⊙\s*/, '');
        const timeMatch = text.match(/과\s*([^에]+)에 많이/);
        if (timeMatch) time = timeMatch[1].trim();
      }
      if (text.includes('월간 추이는')) trend = text.replace(/^⊙\s*/, '');
    }
    for (const row of rows) {
      const index = row.findIndex(value => String(value).includes('분석기간'));
      if (index >= 0) {
        for (let column = index + 1; column < row.length; column++) {
          const match = String(row[column] || '').match(/(20\d{2})년\s*(\d{1,2})월/);
          if (match) { month = `${match[1]}-${String(match[2]).padStart(2, '0')}-01`; break; }
        }
      }
    }
    const behaviors = [];
    const headerRow = rows.findIndex(row => row.some(value => String(value).trim() === '구분') && row.some(value => String(value).includes('과속')));
    let total = null;
    if (headerRow >= 0) {
      const headers = [];
      let current = '';
      for (let column = 0; column < rows[headerRow].length; column++) {
        const value = String(rows[headerRow][column] || '').replace(/\s/g, '');
        if (value) current = value;
        headers[column] = current;
      }
      if (rows[headerRow + 1]) {
        for (let column = 0; column < rows[headerRow + 1].length; column++) {
          const sub = String(rows[headerRow + 1][column] || '').replace(/\s/g, '');
          if (sub && headers[column] === '급회전') headers[column] = `급회전-${sub}`;
        }
      }
      const data = [];
      for (let rowIndex = headerRow + 2; rowIndex < Math.min(rows.length, headerRow + 12); rowIndex++) {
        const label = rows[rowIndex].map(value => String(value || '').trim()).find(value => /^20\d{2}-\d{2}월$/.test(value) || value === '증감');
        if (label) data.push({ label, row: rows[rowIndex] });
      }
      const currentRow = data.find(item => month && item.label.startsWith(month.slice(0, 7))) || data.filter(item => item.label !== '증감').slice(-1)[0];
      const previous = data.filter(item => item.label !== '증감' && item !== currentRow).slice(-1)[0];
      const change = data.find(item => item.label === '증감');
      const seen = new Set();
      if (currentRow) {
        for (let column = 0; column < currentRow.row.length; column++) {
          const header = headers[column];
          if (!header || seen.has(header) || header === '합계' || header === '구분') continue;
          const currentScore = currentRow.row[column];
          if (currentScore === '' || currentScore == null) continue;
          seen.add(header);
          behaviors.push({
            behavior: header,
            current_score: String(currentScore),
            previous_score: previous ? String(previous.row[column] ?? '') : '',
            change_score: change ? String(change.row[column] ?? '') : '',
            grade: '',
          });
        }
        const totalIndex = headers.findIndex(value => value === '합계');
        if (totalIndex >= 0) total = Number(currentRow.row[totalIndex] || 0);
      }
    }
    const recommendations = [];
    for (let index = 0; index < rows.length; index++) {
      const title = String(rows[index]?.[1] || rows[index]?.[0] || '').trim();
      if (/^\d+\.\s*["“]/.test(title)) {
        const body = String(rows[index + 1]?.[1] || rows[index + 1]?.[0] || '').trim();
        if (body) recommendations.push({ title, text: body });
      }
    }
    return {
      driver_name: driver,
      analysis_month: month || `${new Date().toISOString().slice(0, 7)}-01`,
      safety_level: level,
      total_score: Number.isFinite(total) ? total : null,
      summary_text: summary,
      weekday_text: weekday,
      time_text: time,
      trend_text: trend,
      recommendations,
      behaviors,
      source_file: filename,
    };
  }

  async function loadEtasHistory() {
    const data = await rpc('admin_driver_reports', { p_token: token(), p_driver_name: null, p_limit: 100 });
    const rows = data.etas || [];
    $('#etasHistory').innerHTML = rows.length ? `<div class="table-wrap"><table><thead><tr><th>등록시각</th><th>운전자</th><th>분석월</th><th>안전수준</th><th>점수</th><th>수집방식</th><th>원본파일</th><th>기사확인</th></tr></thead><tbody>${rows.map(row => `<tr><td>${fmtDT(row.imported_at)}</td><td><b>${esc(row.driver_name)}</b></td><td>${esc(row.analysis_month).slice(0, 7)}</td><td>${badge(row.safety_level || '-')}</td><td>${row.total_score ?? '-'}</td><td>${badge(row.import_source === 'collector' ? '자동' : '수동')}</td><td>${esc(row.source_file || '-')}</td><td>${row.acknowledged_at ? `<span class="ack-ok">${fmtDT(row.acknowledged_at)}</span>` : '<span class="ack-wait">미확인</span>'}</td></tr>`).join('')}</tbody></table></div>` : '<div class="card empty">등록된 eTAS 리포트가 없습니다.</div>';
  }

  // ---------- Admin driver reports ----------
  async function reportsPage() {
    $('#page').innerHTML = `<div class="card"><div class="toolbar"><label>기사 선택<select id="reportDriver"><option value="">전체 기사</option></select></label><button id="loadReports" class="btn primary">조회</button></div><p class="small muted">교통안전공단 eTAS 공식점수와 CDT 자체 후보분석은 서로 구분하여 표시합니다.</p></div><div id="reportContent"></div>`;
    const initial = await rpc('admin_driver_reports', { p_token: token(), p_driver_name: null, p_limit: 300 });
    $('#reportDriver').innerHTML += (initial.drivers || []).map(driver => `<option value="${esc(driver.display_name)}">${esc(driver.display_name)}</option>`).join('');
    $('#loadReports').onclick = loadDriverReports;
    renderDriverReports(initial);
  }

  async function loadDriverReports() {
    const name = $('#reportDriver').value;
    const data = await rpc('admin_driver_reports', { p_token: token(), p_driver_name: name || null, p_limit: 300 });
    renderDriverReports(data);
  }

  function renderDriverReports(data) {
    const etas = data.etas || [];
    const cdt = data.cdt || [];
    $('#reportContent').innerHTML = `
      <div class="section-title"><h3>교통안전공단 eTAS 공식 리포트</h3><span>${etas.length}건</span></div>
      ${etas.length ? `<div class="report-card-grid">${etas.map(report => `<article class="report-card"><div class="report-head"><div><b>${esc(report.driver_name)}</b><small>${esc(report.analysis_month).slice(0, 7)} · ${report.import_source === 'collector' ? '자동수집' : '수동등록'}</small></div>${badge(report.safety_level || '-')}</div><div class="score-line"><strong>${report.total_score ?? '-'}</strong><span>종합점수</span></div><p>${esc(report.summary_text || '종합진단 내용 없음')}</p><div class="behavior-grid">${(report.behaviors || []).slice(0, 12).map(item => `<div class="behavior-item"><span>${esc(item.behavior)}</span><b>${item.current_score ?? '-'}</b></div>`).join('')}</div><div class="report-foot">기사확인: ${report.acknowledged_at ? `<span class="ack-ok">${fmtDT(report.acknowledged_at)}</span>` : '<span class="ack-wait">미확인</span>'}</div></article>`).join('')}</div>` : '<div class="card empty">eTAS 자료가 없습니다.</div>'}
      <div class="section-title"><h3>CDT(TACO) 자체 후보분석</h3><span>${cdt.length}건</span></div>
      ${tableTaco(cdt)}`;
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
    $('#page').innerHTML = `<div class="card"><h3>자료수집 구조</h3><div class="source-flow"><div><b>배차표</b><span>관리자 다중 업로드</span></div><i>→</i><div><b>CDT/TACO</b><span>ADTviewer 폴더 자동감시</span></div><i>→</i><div><b>eTAS</b><span>다운로드 폴더 자동감시</span></div><i>→</i><div><b>BIS/TAGO</b><span>실시간 API 차량변경 감시</span></div></div><p class="small muted">로컬 Collector 제어센터를 닫아도 Windows 백그라운드 예약작업은 계속 실행됩니다.</p></div><div id="collectorContent"></div>`;
    await loadCollectorStatus();
    state.refreshTimer = setInterval(() => {
      if (state.page === 'collector') loadCollectorStatus(true).catch(() => {});
    }, 10000);
  }

  async function loadCollectorStatus(silent = false) {
    const data = await rpc('admin_collector_status', { p_token: token(), p_limit: 80 });
    const agents = data.agents || [];
    const activities = data.activities || [];
    $('#collectorContent').innerHTML = `
      <div class="section-title"><h3>Collector Agent</h3><span>서버시간 ${fmtDT(data.server_time)}</span></div>
      ${agents.length ? agents.map(agent => `<div class="card collector-agent"><div class="agent-head"><div><b>${esc(agent.agent_id)}</b><small>${esc(agent.host_name || '')} · ${esc(agent.version || '')}</small></div>${badge(agent.online ? 'ONLINE' : agent.status || 'OFFLINE')}</div><div class="grid cols-4 compact-metrics"><div class="metric"><span class="label">마지막 Heartbeat</span><span class="value mini">${fmtDT(agent.last_heartbeat_at)}</span></div><div class="metric"><span class="label">CDT 검색</span><span class="value mini">${agent.last_taco_scan_at ? fmtDT(agent.last_taco_scan_at) : '-'}</span></div><div class="metric"><span class="label">BIS 조회</span><span class="value mini">${agent.last_bis_poll_at ? fmtDT(agent.last_bis_poll_at) : '-'}</span></div><div class="metric"><span class="label">eTAS 검색</span><span class="value mini">${agent.last_etas_scan_at ? fmtDT(agent.last_etas_scan_at) : '-'}</span></div></div><div class="agent-counters">CDT ${agent.counters?.taco_files || 0}파일 · eTAS ${agent.counters?.etas_files || 0}파일 · BIS 조회 ${agent.counters?.bis_polls || 0}회 · 차량변경 ${agent.counters?.bis_changes || 0}건</div>${agent.last_error ? `<div class="notice warn">최근 오류: ${esc(agent.last_error)}</div>` : ''}<div class="toolbar"><button class="btn secondary collector-command" data-agent="${esc(agent.agent_id)}" data-command="reload">설정 재읽기</button><button class="btn secondary collector-command" data-agent="${esc(agent.agent_id)}" data-command="restart">재시작 요청</button><button class="btn danger collector-command" data-agent="${esc(agent.agent_id)}" data-command="stop">종료 요청</button></div></div>`).join('') : '<div class="card empty">등록된 Collector가 없습니다. 회사 PC에서 백그라운드 Collector를 설치·실행하세요.</div>'}
      <div class="section-title"><h3>최근 수집 활동</h3></div>
      ${activities.length ? `<div class="table-wrap"><table><thead><tr><th>시각</th><th>Agent</th><th>구분</th><th>수준</th><th>내용</th></tr></thead><tbody>${activities.map(item => `<tr><td>${fmtDT(item.created_at)}</td><td>${esc(item.agent_id || '-')}</td><td>${esc(item.category)}</td><td>${badge(item.level)}</td><td>${esc(item.message)}</td></tr>`).join('')}</tbody></table></div>` : '<div class="card empty">활동내역이 없습니다.</div>'}
      <div class="section-title"><h3>최근 eTAS 자동/수동 등록</h3></div>
      ${data.etas_recent?.length ? `<div class="table-wrap"><table><thead><tr><th>등록일시</th><th>기사</th><th>분석월</th><th>수준</th><th>수집</th><th>파일</th></tr></thead><tbody>${data.etas_recent.map(item => `<tr><td>${fmtDT(item.imported_at)}</td><td>${esc(item.driver_name)}</td><td>${esc(item.analysis_month).slice(0, 7)}</td><td>${esc(item.safety_level || '-')}</td><td>${item.import_source === 'collector' ? '자동' : '수동'}</td><td>${esc(item.source_file || '-')}</td></tr>`).join('')}</tbody></table></div>` : '<div class="card empty">eTAS 등록내역이 없습니다.</div>'}
      <div class="section-title"><h3>최근 CDT 자동수집</h3></div>${tableImports(data.taco_recent || [])}`;
    $$('.collector-command').forEach(button => {
      button.onclick = async () => {
        const command = button.dataset.command;
        if (!confirm(`Collector에 ${command} 요청을 보낼까요?`)) return;
        try {
          await rpc('admin_collector_command', { p_token: token(), p_agent_id: button.dataset.agent, p_command: command });
          toast('명령을 등록했습니다. Collector가 다음 heartbeat에서 처리합니다.');
          setTimeout(() => loadCollectorStatus(true), 2000);
        } catch (error) { toast(error.message, true); }
      };
    });
    if (!silent) toast('수집현황을 불러왔습니다.');
  }

  async function driversPage() {
    const rows = await rpc('admin_list_users', { p_token: token() });
    $('#page').innerHTML = `<div class="notice">배차표 또는 eTAS 업로드 시 기사 이름으로 계정이 자동 생성됩니다. 초기 비밀번호는 1111이며 첫 로그인 후 변경이 강제됩니다.</div><div class="section-title"><h3>사용자</h3></div><div class="table-wrap"><table><thead><tr><th>ID</th><th>이름</th><th>역할</th><th>비밀번호변경</th><th>최근로그인</th><th></th></tr></thead><tbody>${rows.map(row => `<tr><td>${esc(row.login_id)}</td><td><b>${esc(row.display_name)}</b></td><td>${row.role}</td><td>${row.must_change_password ? '필요' : '완료'}</td><td>${row.last_login_at ? fmtDT(row.last_login_at) : '-'}</td><td>${row.role === 'driver' ? `<button class="btn danger resetpw" data-id="${row.id}">1111로 초기화</button>` : ''}</td></tr>`).join('')}</tbody></table></div>`;
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
    const data = await rpc('driver_dashboard', { p_token: token(), p_limit: 20 });
    const latest = data.etas?.[0];
    const publication = data.publications?.[0];
    $('#page').innerHTML = `<div class="card driver-hero"><span class="kicker">MY SAFE DRIVE</span><h2>${esc(state.session.display_name)} 기사님</h2><div class="grid cols-3"><div class="metric"><span class="label muted">최근 eTAS 안전수준</span><span class="level">${esc(latest?.safety_level || '자료 없음')}</span></div><div class="metric"><span class="label muted">최근 종합점수</span><span class="level">${latest?.total_score ?? '-'}</span></div><div class="metric"><span class="label muted">공개자료 확인</span><span class="level">${publication ? (publication.acknowledged ? '완료' : '미확인') : '-'}</span></div></div></div>
      ${latest ? `<div class="section-title"><h3>교통안전공단 공식 분석</h3></div><div class="card"><p>${esc(latest.summary_text || '')}</p><p>${esc(latest.weekday_text || '')}</p><p>${esc(latest.trend_text || '')}</p><div class="behavior-grid">${(latest.behaviors || []).map(item => `<div class="behavior-item"><span>${esc(item.behavior)}</span><b>${item.current_score ?? '-'}</b></div>`).join('')}</div></div>` : ''}
      <div class="section-title"><h3>나에게 공개된 분석결과</h3></div>${renderPublications(data.publications)}
      <div class="section-title"><h3>최근 CDT 후보 이벤트 요약</h3></div>${tableTaco(data.taco_daily || [])}`;
    $$('.ackbtn').forEach(button => button.onclick = async () => {
      try { await rpc('driver_acknowledge', { p_token: token(), p_publication_id: Number(button.dataset.id), p_comment: null }); toast('확인 처리했습니다.'); driverDashboard(); } catch (error) { toast(error.message, true); }
    });
  }

  function renderPublications(rows) {
    if (!rows?.length) return '<div class="card empty">공개된 분석자료가 없습니다.</div>';
    return rows.map(publication => `<div class="pub-card"><div class="pub-head"><div><b>${esc(publication.title)}</b><div class="small muted">${publication.period_start} ~ ${publication.period_end} · ${esc(publication.source)}</div></div><div>${publication.acknowledged ? '<span class="badge good">확인완료</span>' : `<button class="btn primary ackbtn" data-id="${publication.id}">확인했습니다</button>`}</div></div><p>${esc(publication.summary?.summary_text || '')}</p>${publication.source === 'CDT' ? `<div class="small muted" style="margin-bottom:10px">운행거리 ${num(publication.summary.distance_km).toFixed(1)}km · 차량 ${(publication.summary.vehicles || []).map(esc).join(', ') || '-'} · 노선 ${(publication.summary.routes || []).map(esc).join(', ') || '-'} · 데이터품질 ${esc(publication.summary.data_quality || '-')}</div><div class="behavior-grid"><div class="behavior-item"><span>급출발 후보</span><b>${publication.summary.rapid_start || 0}</b></div><div class="behavior-item"><span>급가속 후보</span><b>${publication.summary.rapid_accel || 0}</b></div><div class="behavior-item"><span>급감속 후보</span><b>${publication.summary.rapid_decel || 0}</b></div><div class="behavior-item"><span>급정지 후보</span><b>${publication.summary.rapid_stop || 0}</b></div><div class="behavior-item"><span>관리속도 초과 후보</span><b>${publication.summary.speed_watch || 0}</b></div></div>` : ''}</div>`).join('');
  }

  async function driverHistory() {
    const data = await rpc('driver_dashboard', { p_token: token(), p_limit: 100 });
    $('#page').innerHTML = `<div class="section-title"><h3>배차·운행이력</h3></div>${data.dispatch?.length ? `<div class="table-wrap"><table><thead><tr><th>일자</th><th>차량</th><th>노선</th><th>순번</th><th>근무</th></tr></thead><tbody>${data.dispatch.map(row => `<tr><td>${row.service_date}</td><td>${esc(row.vehicle_no)}</td><td>${esc(row.route_no)}</td><td>${row.run_order > 0 ? row.run_order : '-'}</td><td>${row.shift_start ? fmtDT(row.shift_start) : row.shift_type}</td></tr>`).join('')}</tbody></table></div>` : '<div class="card empty">배차 이력이 없습니다.</div>'}<div class="section-title"><h3>차량교체 이력</h3></div>${tableChanges(data.vehicle_changes || [])}`;
  }

  function settingsPage() {
    $('#page').innerHTML = `<div class="grid cols-2"><div class="card"><h3>비밀번호 변경</h3><div class="form-grid"><label>현재 비밀번호<input id="spOld" type="password"></label><label>새 비밀번호<input id="spNew" type="password"></label></div><button id="spBtn" class="btn primary">변경</button></div>${state.session.role === 'admin' ? `<div class="card"><h3>Supabase 연결</h3><label>URL<input id="cfgUrl" value="${esc(state.cfg.url)}"></label><label>anon/publishable key<textarea id="cfgKey" rows="3">${esc(state.cfg.key)}</textarea></label><button id="cfgBtn" class="btn secondary">브라우저 설정 저장</button></div><div class="card span-2"><h3>백그라운드 자동수집기</h3><ol class="install-steps"><li><code>collector/setup_windows.bat</code> 실행 및 설정 저장</li><li><code>install_autostart_task.bat</code>를 관리자 권한으로 실행</li><li><code>collector_control.bat</code>에서 시작·종료·상태 확인</li></ol><div class="code-note">CDT 자동수집: E:\\Choyoung\\ADTviewer\\Data<br>eTAS 자동수집: collector_config.json의 etas_folder<br>BIS: 국토교통부 TAGO 실시간 조회<br>Collector 제어창을 닫아도 수집은 계속됨</div></div>` : ''}</div>`;
    $('#spBtn').onclick = async () => {
      try { await rpc('app_change_password', { p_token: token(), p_old_password: $('#spOld').value, p_new_password: $('#spNew').value }); toast('비밀번호를 변경했습니다.'); } catch (error) { toast(error.message, true); }
    };
    if ($('#cfgBtn')) $('#cfgBtn').onclick = () => { saveCfg($('#cfgUrl').value.trim(), $('#cfgKey').value.trim()); toast('저장했습니다.'); };
  }

  init();
})();
