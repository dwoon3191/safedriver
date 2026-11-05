from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import threading
import time
import tkinter as tk
from datetime import date, datetime
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from daewoon_collector import DEFAULT_CONFIG, Supabase, Tago

BASE_DIR = Path(__file__).resolve().parent
STATUS_PATH = BASE_DIR / 'collector_status.json'
CONFIG_PATH = BASE_DIR / 'collector_config.json'
STATE_PATH = BASE_DIR / 'collector_state.json'
LOG_PATH = BASE_DIR / 'collector.log'
STOP_PATH = BASE_DIR / 'collector.stop'
TASK_NAME = 'DaewoonSafeDriveCollector'
CONTROL_VERSION = 'SafeDriveControl-1.4.1'


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding='utf-8-sig'))
    except Exception:
        return dict(default) if isinstance(default, dict) else default


def save_json_atomic(path: Path, value) -> None:
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    tmp.replace(path)


def no_window_flags():
    return getattr(subprocess, 'CREATE_NO_WINDOW', 0)


def task_exists() -> bool:
    result = subprocess.run(
        ['schtasks', '/Query', '/TN', TASK_NAME],
        capture_output=True,
        text=True,
        creationflags=no_window_flags(),
    )
    return result.returncode == 0


def pythonw_path() -> Path:
    current = Path(sys.executable)
    candidate = current.with_name('pythonw.exe')
    return candidate if candidate.exists() else current


def run_task() -> None:
    if STOP_PATH.exists():
        try:
            STOP_PATH.unlink()
        except Exception:
            pass
    if task_exists():
        result = subprocess.run(
            ['schtasks', '/Run', '/TN', TASK_NAME],
            capture_output=True,
            text=True,
            creationflags=no_window_flags(),
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr or result.stdout or '예약작업 시작 실패')
        return
    subprocess.Popen(
        [str(pythonw_path()), str(BASE_DIR / 'daewoon_collector.py'), '--service'],
        cwd=str(BASE_DIR),
        creationflags=(
            getattr(subprocess, 'DETACHED_PROCESS', 0)
            | getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0)
            | getattr(subprocess, 'CREATE_NO_WINDOW', 0)
        ),
        close_fds=True,
    )


def stop_task() -> None:
    STOP_PATH.write_text('stop', encoding='ascii')
    for _ in range(30):
        status = load_json(STATUS_PATH, {})
        if status.get('status') in ('stopped', 'error'):
            break
        time.sleep(0.2)
    if task_exists():
        subprocess.run(
            ['schtasks', '/End', '/TN', TASK_NAME],
            capture_output=True,
            text=True,
            creationflags=no_window_flags(),
        )


def install_task_elevated() -> None:
    script = BASE_DIR / 'tools' / 'install_autostart_task.bat'
    if not script.exists():
        raise RuntimeError('자동실행 설치 도구가 없습니다.')
    command = (
        "Start-Process -FilePath '" + str(script).replace("'", "''") + "' "
        "-WorkingDirectory '" + str(BASE_DIR).replace("'", "''") + "' -Verb RunAs -Wait"
    )
    subprocess.Popen(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command])


def remove_task_elevated() -> None:
    script = BASE_DIR / 'tools' / 'remove_autostart_task.bat'
    if not script.exists():
        raise RuntimeError('자동실행 제거 도구가 없습니다.')
    command = (
        "Start-Process -FilePath '" + str(script).replace("'", "''") + "' "
        "-WorkingDirectory '" + str(BASE_DIR).replace("'", "''") + "' -Verb RunAs -Wait"
    )
    subprocess.Popen(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command])


def open_path(path) -> None:
    try:
        os.startfile(str(path))
    except Exception as exc:
        messagebox.showerror('열기 오류', str(exc))


class ControlCenter(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title('대운교통 SafeDrive Collector 통합 제어센터')
        self.geometry('1000x760')
        self.minsize(920, 680)
        self.configure(bg='#eef4f8')
        self.protocol('WM_DELETE_WINDOW', self.destroy)
        self.fields: dict[str, tk.Variable] = {}
        self.diag_running = False
        self.status_vars = {
            key: tk.StringVar(value='-')
            for key in (
                'status', 'agent', 'heartbeat', 'taco', 'bis', 'pending',
                'success', 'counts', 'bis_detail', 'error', 'task'
            )
        }
        self.build()
        self.load_config_to_form()
        self.after(300, self.refresh)
        if not CONFIG_PATH.exists():
            self.after(700, lambda: self.notebook.select(self.config_tab))

    def build(self):
        header = tk.Frame(self, bg='#0e3558', height=92)
        header.pack(fill='x')
        tk.Label(header, text='SafeDrive Collector 통합 제어센터',
                 font=('Malgun Gothic', 20, 'bold'), fg='white', bg='#0e3558').pack(anchor='w', padx=26, pady=(16, 0))
        tk.Label(header,
                 text='설정 · 연결진단 · 백그라운드 자동수집 · BIS/CDT 연계상태를 한 프로그램에서 관리',
                 font=('Malgun Gothic', 10), fg='#c9e5f7', bg='#0e3558').pack(anchor='w', padx=26, pady=(2, 14))

        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill='both', expand=True, padx=18, pady=16)
        self.status_tab = tk.Frame(self.notebook, bg='#eef4f8')
        self.config_tab = tk.Frame(self.notebook, bg='#eef4f8')
        self.diag_tab = tk.Frame(self.notebook, bg='#eef4f8')
        self.notebook.add(self.status_tab, text='운영상태')
        self.notebook.add(self.config_tab, text='환경설정')
        self.notebook.add(self.diag_tab, text='연결진단')
        self.build_status_tab()
        self.build_config_tab()
        self.build_diag_tab()

    def build_status_tab(self):
        body = tk.Frame(self.status_tab, bg='#eef4f8')
        body.pack(fill='both', expand=True, padx=6, pady=8)
        card = tk.Frame(body, bg='white', highlightbackground='#d8e3eb', highlightthickness=1)
        card.pack(fill='x')
        rows = [
            ('작동상태', 'status'), ('Agent / 버전', 'agent'), ('Windows 자동실행', 'task'),
            ('마지막 Heartbeat', 'heartbeat'), ('CDT 마지막 검색', 'taco'), ('BIS 마지막 조회', 'bis'),
            ('CDT 매칭 대기', 'pending'), ('마지막 정상처리', 'success'), ('수집 건수', 'counts'),
            ('최근 BIS 비교', 'bis_detail'), ('최근 오류', 'error'),
        ]
        for idx, (label, key) in enumerate(rows):
            tk.Label(card, text=label, width=18, anchor='w', bg='#f6f9fb', fg='#345068',
                     font=('Malgun Gothic', 10, 'bold')).grid(row=idx, column=0, sticky='nsew', padx=(0, 1), pady=(0, 1))
            tk.Label(card, textvariable=self.status_vars[key], anchor='w', justify='left', wraplength=700,
                     bg='white', fg='#152e42', font=('Malgun Gothic', 10)).grid(row=idx, column=1, sticky='nsew', padx=12, pady=7)
        card.grid_columnconfigure(1, weight=1)

        buttons = tk.Frame(body, bg='#eef4f8')
        buttons.pack(fill='x', pady=14)
        specs = [
            ('수집 시작', self.start_collector, '#155d91'), ('수집 종료', self.stop_collector, '#a33a42'),
            ('재시작', self.restart_collector, '#4e7088'), ('연결진단', lambda: (self.notebook.select(self.diag_tab), self.run_diagnostics()), '#16866f'),
            ('자동실행 설치', self.install_autostart, '#ffffff'), ('자동실행 제거', self.remove_autostart, '#ffffff'),
            ('로그 열기', lambda: open_path(LOG_PATH), '#ffffff'), ('웹앱 열기', self.open_web, '#ffffff'),
        ]
        for text, command, color in specs:
            fg = 'white' if color != '#ffffff' else '#173d5b'
            tk.Button(buttons, text=text, command=command, bg=color, fg=fg, activebackground=color,
                      activeforeground=fg, relief='flat', padx=12, pady=9,
                      font=('Malgun Gothic', 9, 'bold'), cursor='hand2').pack(side='left', padx=(0, 7), pady=3)

        tk.Label(body,
                 text='이 제어센터를 닫아도 Collector는 백그라운드에서 계속 수집합니다. '
                      'collector_config.json과 collector_state.json은 업데이트·시작·종료 과정에서 초기화하지 않습니다.\n'
                      'CDT는 며칠 뒤 도착해도 파일 내부 운행일을 기준으로 과거 배차·BIS 실제차량 이력에 다시 연결합니다.',
                 justify='left', anchor='w', bg='#e8f3fa', fg='#315870', padx=14, pady=12,
                 font=('Malgun Gothic', 9)).pack(fill='x')

    def add_field(self, parent, row, key, label, secret=False, width=64):
        tk.Label(parent, text=label, anchor='w', bg='white', fg='#27475e',
                 font=('Malgun Gothic', 9, 'bold')).grid(row=row, column=0, sticky='w', padx=12, pady=7)
        var = tk.StringVar()
        entry = tk.Entry(parent, textvariable=var, show='●' if secret else '', width=width,
                         font=('Consolas' if key.endswith('key') or 'url' in key else 'Malgun Gothic', 9))
        entry.grid(row=row, column=1, sticky='ew', padx=12, pady=7)
        self.fields[key] = var
        return entry

    def build_config_tab(self):
        outer = tk.Frame(self.config_tab, bg='#eef4f8')
        outer.pack(fill='both', expand=True, padx=6, pady=8)
        card = tk.Frame(outer, bg='white', highlightbackground='#d8e3eb', highlightthickness=1)
        card.pack(fill='both', expand=True)
        card.grid_columnconfigure(1, weight=1)
        rows = [
            ('supabase_url', 'Supabase URL', False), ('supabase_anon_key', 'Publishable / anon key', True),
            ('login_id', '관리자 로그인 ID', False), ('password', '현재 관리자 비밀번호', True),
            ('tago_service_key', 'TAGO 일반 인증키', True), ('city_name', '도시명', False),
            ('city_code', '도시코드(자동이면 빈칸)', False), ('taco_folder', 'CDT 감시 폴더', False),
            ('analysis_folder', '로컬 분석근거 보관 폴더', False), ('web_url', '웹앱 URL', False),
            ('agent_id', 'Collector Agent ID', False),
        ]
        for idx, (key, label, secret) in enumerate(rows):
            self.add_field(card, idx, key, label, secret)
        number_frame = tk.Frame(card, bg='white')
        number_frame.grid(row=len(rows), column=0, columnspan=2, sticky='ew', padx=12, pady=8)
        numeric = [
            ('scan_seconds', 'CDT 검사(초)'), ('stable_seconds', '파일 안정화(초)'),
            ('bis_poll_seconds', 'BIS 조회(초)'), ('bis_confirm_polls', '변경 확인 횟수'),
            ('bis_recent_minutes', 'BIS 최근자료(분)'), ('speed_watch_kmh', '관리속도(km/h)'),
            ('pending_retry_minutes', '미매칭 재시도(분)'), ('pending_retention_days', '미매칭 보존(일)'),
        ]
        for i, (key, label) in enumerate(numeric):
            box = tk.Frame(number_frame, bg='white')
            box.grid(row=i // 4, column=i % 4, padx=6, pady=4, sticky='w')
            tk.Label(box, text=label, bg='white', fg='#456278', font=('Malgun Gothic', 8)).pack(anchor='w')
            var = tk.StringVar()
            tk.Entry(box, textvariable=var, width=12).pack(anchor='w')
            self.fields[key] = var

        toggles = tk.Frame(card, bg='white')
        toggles.grid(row=len(rows)+1, column=0, columnspan=2, sticky='w', padx=12, pady=6)
        for key, label in [('enable_bis', 'BIS/TAGO 수집'), ('enable_taco', 'CDT/TACO 수집')]:
            var = tk.BooleanVar(value=True)
            self.fields[key] = var
            tk.Checkbutton(toggles, text=label, variable=var, bg='white', font=('Malgun Gothic', 9)).pack(side='left', padx=(0, 20))

        actions = tk.Frame(card, bg='white')
        actions.grid(row=len(rows)+2, column=0, columnspan=2, sticky='w', padx=12, pady=12)
        tk.Button(actions, text='설정 저장', command=self.save_config, bg='#155d91', fg='white', relief='flat', padx=20, pady=9,
                  font=('Malgun Gothic', 10, 'bold')).pack(side='left', padx=(0, 8))
        tk.Button(actions, text='CDT 폴더 선택', command=lambda: self.choose_folder('taco_folder'), relief='flat', padx=14, pady=9).pack(side='left', padx=(0, 8))
        tk.Button(actions, text='분석폴더 선택', command=lambda: self.choose_folder('analysis_folder'), relief='flat', padx=14, pady=9).pack(side='left', padx=(0, 8))
        tk.Button(actions, text='설정파일 열기', command=lambda: open_path(CONFIG_PATH), relief='flat', padx=14, pady=9).pack(side='left')
        tk.Label(card,
                 text='비밀번호·API 키는 화면에서 마스킹되며 회사 PC의 collector_config.json에만 저장됩니다. '\
                      'GitHub·Netlify에 업로드하지 마십시오. 상태파일은 저장 시 삭제되지 않습니다.',
                 bg='#fff7dc', fg='#6b5520', justify='left', anchor='w', padx=12, pady=10,
                 font=('Malgun Gothic', 9)).grid(row=len(rows)+3, column=0, columnspan=2, sticky='ew', padx=12, pady=(0, 12))

    def build_diag_tab(self):
        body = tk.Frame(self.diag_tab, bg='#eef4f8')
        body.pack(fill='both', expand=True, padx=6, pady=8)
        top = tk.Frame(body, bg='#eef4f8')
        top.pack(fill='x')
        tk.Button(top, text='전체 연결진단 실행', command=self.run_diagnostics, bg='#16866f', fg='white', relief='flat',
                  padx=18, pady=9, font=('Malgun Gothic', 10, 'bold')).pack(side='left')
        tk.Label(top, text='Supabase 로그인·Collector 명령RPC·CDT 폴더·TAGO 도시/노선/위치 API를 순서대로 검사합니다.',
                 bg='#eef4f8', fg='#456278', font=('Malgun Gothic', 9)).pack(side='left', padx=14)
        self.diag_text = tk.Text(body, wrap='word', font=('Consolas', 10), bg='#0f2638', fg='#d5eefc', insertbackground='white')
        self.diag_text.pack(fill='both', expand=True, pady=(10, 0))
        self.diag_text.insert('end', '연결진단을 실행하십시오. 실제 인증키는 결과창에 표시하지 않습니다.\n')
        self.diag_text.configure(state='disabled')

    def load_config_to_form(self):
        cfg = {**DEFAULT_CONFIG, **load_json(CONFIG_PATH, {})}
        for key, var in self.fields.items():
            value = cfg.get(key, '')
            if isinstance(var, tk.BooleanVar):
                var.set(bool(value))
            else:
                var.set(str(value if value is not None else ''))

    def form_config(self):
        cfg = {**DEFAULT_CONFIG, **load_json(CONFIG_PATH, {})}
        for key, var in self.fields.items():
            value = var.get()
            if isinstance(var, tk.BooleanVar):
                cfg[key] = bool(value)
            elif key in {
                'scan_seconds','stable_seconds','bis_poll_seconds','bis_confirm_polls',
                'bis_recent_minutes','speed_watch_kmh','pending_retry_minutes','pending_retention_days'
            }:
                try: cfg[key] = int(str(value).strip())
                except Exception: raise ValueError(f'{key}는 숫자로 입력하십시오.')
            else:
                cfg[key] = str(value).strip()
        if not cfg.get('agent_id'):
            cfg['agent_id'] = socket.gethostname()
        return cfg

    def save_config(self):
        try:
            cfg = self.form_config()
            required = ['supabase_url','supabase_anon_key','login_id','password']
            missing = [key for key in required if not cfg.get(key)]
            if missing:
                raise ValueError('필수 설정이 비어 있습니다: ' + ', '.join(missing))
            save_json_atomic(CONFIG_PATH, cfg)
            messagebox.showinfo('설정 저장', '설정을 저장했습니다. 기존 collector_state.json은 유지되었습니다.')
        except Exception as exc:
            messagebox.showerror('설정 오류', str(exc))

    def choose_folder(self, key):
        selected = filedialog.askdirectory(initialdir=self.fields[key].get() or str(BASE_DIR))
        if selected:
            self.fields[key].set(selected)

    def _diag_write(self, line):
        def append():
            self.diag_text.configure(state='normal')
            self.diag_text.insert('end', line + '\n')
            self.diag_text.see('end')
            self.diag_text.configure(state='disabled')
        self.after(0, append)

    def run_diagnostics(self):
        if self.diag_running:
            return
        try:
            cfg = self.form_config()
        except Exception as exc:
            messagebox.showerror('설정 오류', str(exc))
            return
        self.diag_running = True
        self.notebook.select(self.diag_tab)
        self.diag_text.configure(state='normal')
        self.diag_text.delete('1.0', 'end')
        self.diag_text.configure(state='disabled')
        threading.Thread(target=self._diagnostic_worker, args=(cfg,), daemon=True).start()

    def _diagnostic_worker(self, cfg):
        try:
            self._diag_write(f'[{datetime.now():%Y-%m-%d %H:%M:%S}] SafeDrive 연결진단 시작 ({CONTROL_VERSION})')
            self._diag_write('1. 설정 파일: ' + ('정상' if CONFIG_PATH.exists() else '아직 저장되지 않음'))
            taco = Path(cfg.get('taco_folder') or '')
            count = len(list(taco.glob('*.CDT'))) if taco.exists() else 0
            self._diag_write(f'2. CDT 폴더: {"정상" if taco.exists() else "오류"} / 감지 가능한 CDT {count}개')
            analysis = Path(cfg.get('analysis_folder') or '')
            try:
                analysis.mkdir(parents=True, exist_ok=True)
                test_file = analysis / '.safedrive_write_test'
                test_file.write_text('ok', encoding='ascii')
                test_file.unlink()
                self._diag_write('3. 로컬 분석폴더 쓰기: 정상')
            except Exception as exc:
                self._diag_write(f'3. 로컬 분석폴더 쓰기: 오류 - {exc}')

            sb = Supabase(cfg)
            sb.login()
            self._diag_write('4. Supabase 관리자 로그인: 정상')
            context = sb.context(date.today())
            dispatch = context.get('dispatch') or []
            timetable = context.get('timetable') or []
            self._diag_write(f'5. Supabase 운영자료 조회: 정상 / 오늘 배차 {len(dispatch)}건 / 시간표 슬롯 {len(timetable)}건')
            try:
                sb.fetch_commands(cfg.get('agent_id') or socket.gethostname())
                self._diag_write('6. Collector 명령 RPC: 정상 (v1.3.0 SQL 적용 확인)')
            except Exception as exc:
                self._diag_write(f'6. Collector 명령 RPC: 오류 - {exc}')
                self._diag_write('   → Supabase에서 sql/07_collector_usage_monthly_fix.sql을 실행하십시오.')

            if cfg.get('enable_bis'):
                if not cfg.get('tago_service_key'):
                    self._diag_write('7. TAGO/BIS: 오류 - 일반 인증키가 비어 있습니다.')
                else:
                    tago = Tago(cfg)
                    city_code = tago.ensure_city()
                    self._diag_write(f'7. TAGO 도시코드 API: 정상 / {cfg.get("city_name")}={city_code}')
                    route = next((str(row.get('route_no')) for row in dispatch if str(row.get('route_no') or '').strip() not in ('','-1')), '')
                    if route:
                        route_id = tago.route_id(route)
                        self._diag_write(f'8. TAGO 노선정보 API: 정상 / 노선 {route} / routeId 확인={bool(route_id)}')
                        positions = tago.locations(route)
                        self._diag_write(f'9. TAGO 버스위치 API: 정상 / 현재 차량 {len(positions)}대')
                    else:
                        self._diag_write('8. TAGO 노선/위치 API: 오늘 등록 배차가 없어 도시코드까지만 검사함')
            else:
                self._diag_write('7. TAGO/BIS: 설정에서 비활성화됨')
            self._diag_write('진단 완료. 오류가 없는 경우 수집 시작 또는 재시작을 누르십시오.')
        except Exception as exc:
            self._diag_write(f'진단 중단: {exc}')
        finally:
            self.diag_running = False

    def start_collector(self):
        try:
            if not CONFIG_PATH.exists():
                self.notebook.select(self.config_tab)
                raise RuntimeError('환경설정을 먼저 저장하십시오.')
            run_task()
            messagebox.showinfo('SafeDrive', 'Collector 시작을 요청했습니다. 제어센터를 닫아도 수집은 계속됩니다.')
        except Exception as exc:
            messagebox.showerror('시작 오류', str(exc))

    def stop_collector(self):
        try:
            stop_task()
            messagebox.showinfo('SafeDrive', 'Collector 종료를 요청했습니다.')
        except Exception as exc:
            messagebox.showerror('종료 오류', str(exc))

    def restart_collector(self):
        try:
            stop_task(); time.sleep(1); run_task()
            messagebox.showinfo('SafeDrive', 'Collector 재시작을 요청했습니다.')
        except Exception as exc:
            messagebox.showerror('재시작 오류', str(exc))

    def install_autostart(self):
        try:
            install_task_elevated()
            messagebox.showinfo('자동실행', '관리자 승인창에서 예를 누르십시오. 설치 후 운영상태에서 확인할 수 있습니다.')
        except Exception as exc:
            messagebox.showerror('자동실행 설치 오류', str(exc))

    def remove_autostart(self):
        try:
            remove_task_elevated()
            messagebox.showinfo('자동실행', '관리자 승인창에서 예를 누르십시오.')
        except Exception as exc:
            messagebox.showerror('자동실행 제거 오류', str(exc))

    def open_web(self):
        cfg = load_json(CONFIG_PATH, {})
        open_path(cfg.get('web_url') or 'https://dwoondriver.netlify.app')

    def refresh(self):
        status = load_json(STATUS_PATH, {})
        state = status.get('status', '실행 기록 없음')
        heartbeat = status.get('last_heartbeat_at', '')
        online = False
        if heartbeat:
            try:
                parsed = datetime.fromisoformat(heartbeat)
                online = (datetime.now(parsed.tzinfo) - parsed).total_seconds() < 90 and state == 'running'
            except Exception:
                pass
        self.status_vars['status'].set('● 실행 중' if online else f'○ {state}')
        self.status_vars['agent'].set(f"{status.get('agent_id','-')} / {status.get('version','-')} / PID {status.get('process_id','-')}")
        self.status_vars['task'].set('설치됨' if task_exists() else '미설치(수동 실행 가능)')
        self.status_vars['heartbeat'].set(heartbeat or '-')
        self.status_vars['taco'].set(status.get('last_taco_scan_at') or '-')
        self.status_vars['bis'].set(status.get('last_bis_poll_at') or '-')
        counters = status.get('counters') or {}
        self.status_vars['pending'].set(f"{counters.get('pending_cdt',0)}건")
        self.status_vars['success'].set(status.get('last_success_at') or '-')
        self.status_vars['counts'].set(
            f"CDT {counters.get('taco_files',0)}파일 / 대표이벤트 {counters.get('taco_events',0)}건 / "
            f"BIS 조회 {counters.get('bis_polls',0)}회 / 실제차량 연결 {counters.get('bis_changes',0)}건"
        )
        summary = counters.get('last_bis_summary') or {}
        details = summary.get('route_details') or []
        detail_text = (
            f"노선 {summary.get('routes',0)} / 예정차량 {summary.get('expected',0)} / "
            f"BIS차량 {summary.get('live',0)} / 불일치후보 {summary.get('mismatches',0)} / "
            f"확정 {summary.get('changes',0)}"
        )
        if details:
            detail_text += ' | ' + ' ; '.join(
                f"{item.get('route')}번 예정[{','.join(item.get('expected_vehicles',[]))}] "
                f"BIS[{','.join(item.get('live_vehicles',[]))}] 누락[{','.join(item.get('missing_vehicles',[]))}] "
                f"추가[{','.join(item.get('unexpected_vehicles',[]))}]"
                for item in details[:5]
            )
        self.status_vars['bis_detail'].set(detail_text)
        self.status_vars['error'].set(status.get('last_error') or '없음')
        self.after(2000, self.refresh)


if __name__ == '__main__':
    ControlCenter().mainloop()
