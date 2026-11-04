from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import tkinter as tk
from datetime import datetime
from pathlib import Path
from tkinter import messagebox

BASE_DIR = Path(__file__).resolve().parent
STATUS_PATH = BASE_DIR / 'collector_status.json'
CONFIG_PATH = BASE_DIR / 'collector_config.json'
LOG_PATH = BASE_DIR / 'collector.log'
STOP_PATH = BASE_DIR / 'collector.stop'
TASK_NAME = 'DaewoonSafeDriveCollector'


def load_json(path, default):
    try:
        return json.loads(path.read_text(encoding='utf-8-sig'))
    except Exception:
        return default


def open_path(path):
    try:
        os.startfile(str(path))
    except Exception as exc:
        messagebox.showerror('오류', str(exc))


def task_exists():
    result = subprocess.run(
        ['schtasks', '/Query', '/TN', TASK_NAME],
        capture_output=True,
        text=True,
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
    )
    return result.returncode == 0


def run_task():
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
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr or result.stdout or '예약작업 시작 실패')
    else:
        pyw = Path(sys.executable).with_name('pythonw.exe')
        executable = pyw if pyw.exists() else Path(sys.executable)
        subprocess.Popen(
            [str(executable), str(BASE_DIR / 'daewoon_collector.py'), '--service'],
            cwd=str(BASE_DIR),
            creationflags=(
                getattr(subprocess, 'DETACHED_PROCESS', 0)
                | getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0)
                | getattr(subprocess, 'CREATE_NO_WINDOW', 0)
            ),
            close_fds=True,
        )


def stop_task():
    STOP_PATH.write_text('stop', encoding='ascii')
    # Allow the service to stop gracefully before ending the scheduled task.
    for _ in range(20):
        status = load_json(STATUS_PATH, {})
        if status.get('status') in ('stopped', 'error'):
            return
        time.sleep(0.25)
    if task_exists():
        subprocess.run(
            ['schtasks', '/End', '/TN', TASK_NAME],
            capture_output=True,
            text=True,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
        )


class ControlCenter(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title('대운교통 SafeDrive Collector 제어센터')
        self.geometry('760x570')
        self.minsize(720, 520)
        self.configure(bg='#eef4f8')
        self.protocol('WM_DELETE_WINDOW', self.destroy)
        self.status_vars = {
            key: tk.StringVar(value='-')
            for key in (
                'status',
                'agent',
                'version',
                'heartbeat',
                'taco',
                'bis',
                'etas',
                'success',
                'error',
                'counts',
            )
        }
        self.build()
        self.after(300, self.refresh)

    def build(self):
        header = tk.Frame(self, bg='#0e3558', height=92)
        header.pack(fill='x')
        tk.Label(
            header,
            text='SafeDrive Collector Control Center',
            font=('Malgun Gothic', 19, 'bold'),
            fg='white',
            bg='#0e3558',
        ).pack(anchor='w', padx=24, pady=(18, 0))
        tk.Label(
            header,
            text='CDT · eTAS · TAGO/BIS 백그라운드 수집 상태와 시작·종료 관리',
            font=('Malgun Gothic', 10),
            fg='#c9e5f7',
            bg='#0e3558',
        ).pack(anchor='w', padx=24, pady=(2, 15))

        body = tk.Frame(self, bg='#eef4f8')
        body.pack(fill='both', expand=True, padx=22, pady=18)

        status_card = tk.Frame(body, bg='white', highlightbackground='#d8e3eb', highlightthickness=1)
        status_card.pack(fill='x')
        rows = [
            ('작동상태', 'status'),
            ('Agent / 버전', 'agent'),
            ('마지막 Heartbeat', 'heartbeat'),
            ('CDT 마지막 검색', 'taco'),
            ('BIS 마지막 조회', 'bis'),
            ('eTAS 마지막 검색', 'etas'),
            ('마지막 정상처리', 'success'),
            ('수집 건수', 'counts'),
            ('최근 오류', 'error'),
        ]
        for index, (label, key) in enumerate(rows):
            tk.Label(
                status_card,
                text=label,
                width=17,
                anchor='w',
                bg='#f6f9fb',
                fg='#345068',
                font=('Malgun Gothic', 10, 'bold'),
            ).grid(row=index, column=0, sticky='nsew', padx=(0, 1), pady=(0, 1))
            tk.Label(
                status_card,
                textvariable=self.status_vars[key],
                anchor='w',
                justify='left',
                wraplength=510,
                bg='white',
                fg='#152e42',
                font=('Malgun Gothic', 10),
            ).grid(row=index, column=1, sticky='nsew', padx=12, pady=8)
        status_card.grid_columnconfigure(1, weight=1)

        button_box = tk.Frame(body, bg='#eef4f8')
        button_box.pack(fill='x', pady=16)
        buttons = [
            ('수집 시작', self.start_collector, '#155d91'),
            ('수집 종료', self.stop_collector, '#a33a42'),
            ('재시작', self.restart_collector, '#4e7088'),
            ('설정 열기', lambda: open_path(CONFIG_PATH), '#ffffff'),
            ('로그 열기', lambda: open_path(LOG_PATH), '#ffffff'),
            ('웹앱 열기', self.open_web, '#ffffff'),
        ]
        for text, command, color in buttons:
            fg = 'white' if color != '#ffffff' else '#173d5b'
            button = tk.Button(
                button_box,
                text=text,
                command=command,
                bg=color,
                fg=fg,
                activebackground=color,
                activeforeground=fg,
                relief='flat',
                padx=15,
                pady=9,
                font=('Malgun Gothic', 10, 'bold'),
                cursor='hand2',
            )
            button.pack(side='left', padx=(0, 8))

        info = (
            '이 제어창을 닫아도 Collector는 Windows 예약작업에서 계속 실행됩니다.\n'
            'eTAS 자동수집은 eTAS 보고서를 설정 폴더에 내려받았을 때 작동하며, '
            'CDT는 ADTviewer Data 폴더에서 자동 수집됩니다.'
        )
        tk.Label(
            body,
            text=info,
            justify='left',
            anchor='w',
            bg='#e8f3fa',
            fg='#315870',
            padx=14,
            pady=12,
            font=('Malgun Gothic', 9),
        ).pack(fill='x')

    def start_collector(self):
        try:
            run_task()
            messagebox.showinfo('SafeDrive', 'Collector 시작을 요청했습니다.')
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
            stop_task()
            time.sleep(1)
            run_task()
            messagebox.showinfo('SafeDrive', 'Collector 재시작을 요청했습니다.')
        except Exception as exc:
            messagebox.showerror('재시작 오류', str(exc))

    def open_web(self):
        config = load_json(CONFIG_PATH, {})
        url = config.get('web_url') or 'https://dwoondriver.netlify.app'
        try:
            os.startfile(url)
        except Exception as exc:
            messagebox.showerror('오류', str(exc))

    def refresh(self):
        status = load_json(STATUS_PATH, {})
        state = status.get('status', '실행 기록 없음')
        heartbeat = status.get('last_heartbeat_at', '')
        online = False
        if heartbeat:
            try:
                parsed = datetime.fromisoformat(heartbeat)
                age = (datetime.now(parsed.tzinfo) - parsed).total_seconds()
                online = age < 90 and state == 'running'
            except Exception:
                pass
        self.status_vars['status'].set('● 실행 중' if online else f'○ {state}')
        self.status_vars['agent'].set(
            f"{status.get('agent_id','-')} / {status.get('version','-')} / PID {status.get('process_id','-')}"
        )
        self.status_vars['heartbeat'].set(heartbeat or '-')
        self.status_vars['taco'].set(status.get('last_taco_scan_at') or '-')
        self.status_vars['bis'].set(status.get('last_bis_poll_at') or '-')
        self.status_vars['etas'].set(status.get('last_etas_scan_at') or '-')
        self.status_vars['success'].set(status.get('last_success_at') or '-')
        counters = status.get('counters') or {}
        self.status_vars['counts'].set(
            f"CDT {counters.get('taco_files',0)}파일 / 이벤트 {counters.get('taco_events',0)}건 / "
            f"eTAS {counters.get('etas_files',0)}파일 / BIS 조회 {counters.get('bis_polls',0)}회 / "
            f"변경 {counters.get('bis_changes',0)}건"
        )
        self.status_vars['error'].set(status.get('last_error') or '없음')
        self.after(2000, self.refresh)


if __name__ == '__main__':
    ControlCenter().mainloop()
