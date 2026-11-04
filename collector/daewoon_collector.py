from __future__ import annotations

import argparse
import atexit
import csv
import getpass
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

VERSION = 'DaewoonCollector-1.1.0'
KST = timezone(timedelta(hours=9))
DTG_EPOCH = datetime(2000, 1, 1)
RECORD_SIZE = 128
BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / 'collector_config.json'
STATE_PATH = BASE_DIR / 'collector_state.json'
STATUS_PATH = BASE_DIR / 'collector_status.json'
LOG_PATH = BASE_DIR / 'collector.log'
PID_PATH = BASE_DIR / 'collector.pid'
STOP_PATH = BASE_DIR / 'collector.stop'

DEFAULT_CONFIG = {
    'supabase_url': '',
    'supabase_anon_key': '',
    'login_id': '관리자',
    'password': '',
    'agent_id': '',
    'web_url': 'https://dwoondriver.netlify.app',
    'taco_folder': r'E:\Choyoung\ADTviewer\Data',
    'etas_folder': r'E:\Choyoung\ADTviewer\eTAS',
    'scan_seconds': 5,
    'etas_scan_seconds': 20,
    'stable_seconds': 8,
    'heartbeat_seconds': 15,
    'tago_service_key': '',
    'city_code': '',
    'city_name': '창원시',
    'bis_poll_seconds': 30,
    'bis_confirm_polls': 2,
    'bis_recent_minutes': 12,
    'speed_watch_kmh': 80,
    'enable_bis': True,
    'enable_taco': True,
    'enable_etas_auto': True,
}

_RUNTIME = {
    'agent_id': '',
    'host_name': socket.gethostname(),
    'version': VERSION,
    'status': 'starting',
    'process_id': os.getpid(),
    'started_at': datetime.now(KST).isoformat(),
    'last_heartbeat_at': '',
    'last_taco_scan_at': '',
    'last_bis_poll_at': '',
    'last_etas_scan_at': '',
    'last_success_at': '',
    'last_error': '',
    'counters': {
        'taco_files': 0,
        'taco_events': 0,
        'etas_files': 0,
        'bis_polls': 0,
        'bis_changes': 0,
        'errors': 0,
    },
    'config_summary': {},
}


def now_iso() -> str:
    return datetime.now(KST).isoformat()


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding='utf-8-sig'))
    except Exception:
        return default.copy() if isinstance(default, dict) else default


def save_json(path: Path, obj) -> None:
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding='utf-8')
    tmp.replace(path)


def write_status() -> None:
    try:
        _RUNTIME['last_heartbeat_at'] = now_iso()
        save_json(STATUS_PATH, _RUNTIME)
    except Exception:
        pass


def log(msg: str, *, level: str = 'info') -> None:
    line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    if sys.stdout is not None:
        try:
            print(line, flush=True)
        except Exception:
            pass
    try:
        with LOG_PATH.open('a', encoding='utf-8') as f:
            f.write(line + '\n')
    except Exception:
        pass
    if level == 'error':
        _RUNTIME['last_error'] = msg[:2000]
        _RUNTIME['counters']['errors'] = int(_RUNTIME['counters'].get('errors', 0)) + 1
    write_status()


def mark_success() -> None:
    _RUNTIME['last_success_at'] = now_iso()
    _RUNTIME['last_error'] = ''
    write_status()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def process_exists(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def acquire_single_instance() -> None:
    if PID_PATH.exists():
        try:
            old_pid = int(PID_PATH.read_text(encoding='ascii').strip())
        except Exception:
            old_pid = 0
        if old_pid and process_exists(old_pid):
            raise RuntimeError(f'Collector가 이미 실행 중입니다. PID={old_pid}')
    PID_PATH.write_text(str(os.getpid()), encoding='ascii')


def cleanup_instance() -> None:
    try:
        if PID_PATH.exists() and PID_PATH.read_text(encoding='ascii').strip() == str(os.getpid()):
            PID_PATH.unlink()
    except Exception:
        pass


class Supabase:
    def __init__(self, cfg):
        self.url = cfg['supabase_url'].rstrip('/')
        self.key = cfg['supabase_anon_key']
        self.token = ''
        self.cfg = cfg

    def rpc(self, fn, payload, timeout=50):
        url = f"{self.url}/rest/v1/rpc/{fn}"
        data = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        req = urllib.request.Request(
            url,
            data=data,
            method='POST',
            headers={
                'Content-Type': 'application/json',
                'apikey': self.key,
                'Authorization': 'Bearer ' + self.key,
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                body = response.read()
                return json.loads(body.decode('utf-8')) if body else None
        except urllib.error.HTTPError as exc:
            body = exc.read().decode('utf-8', 'replace')
            try:
                message = json.loads(body).get('message', body)
            except Exception:
                message = body
            raise RuntimeError(f'Supabase {fn}: {message}') from exc
        except Exception as exc:
            raise RuntimeError(f'Supabase {fn}: {exc}') from exc

    def login(self):
        password = self.cfg.get('password') or getpass.getpass(
            f"{self.cfg.get('login_id', '관리자')} 비밀번호: "
        )
        session = self.rpc(
            'app_login',
            {
                'p_login_id': self.cfg.get('login_id', '관리자'),
                'p_password': password,
            },
        )
        if session.get('must_change_password'):
            raise RuntimeError('관리자 초기 비밀번호를 웹앱에서 먼저 변경하세요.')
        self.token = session['token']
        log(f"Supabase 로그인: {session.get('display_name')}")

    def dispatch(self, service_date: date):
        return self.rpc(
            'collector_get_dispatch',
            {'p_token': self.token, 'p_service_date': service_date.isoformat()},
        ) or []

    def changes(self, service_date: date):
        return self.rpc(
            'collector_get_vehicle_changes',
            {'p_token': self.token, 'p_service_date': service_date.isoformat()},
        ) or []

    def ingest_changes(self, rows):
        return self.rpc(
            'collector_ingest_vehicle_changes',
            {'p_token': self.token, 'p_changes': rows},
        )

    def ingest_taco(self, import_info, events, summaries):
        return self.rpc(
            'collector_ingest_taco',
            {
                'p_token': self.token,
                'p_import': import_info,
                'p_events': events,
                'p_summaries': summaries,
            },
            timeout=120,
        )

    def import_etas(self, report):
        return self.rpc(
            'admin_import_etas',
            {'p_token': self.token, 'p_report': report},
            timeout=90,
        )

    def heartbeat(self, payload):
        return self.rpc(
            'collector_heartbeat',
            {'p_token': self.token, 'p_agent': payload},
            timeout=30,
        )

    def activity(self, event):
        return self.rpc(
            'collector_activity',
            {'p_token': self.token, 'p_event': event},
            timeout=30,
        )

    def fetch_commands(self, agent_id):
        return self.rpc(
            'collector_fetch_commands',
            {'p_token': self.token, 'p_agent_id': agent_id},
            timeout=30,
        ) or []

    def complete_command(self, command_id, ok, result=''):
        return self.rpc(
            'collector_complete_command',
            {
                'p_token': self.token,
                'p_command_id': command_id,
                'p_ok': bool(ok),
                'p_result': result,
            },
            timeout=30,
        )


# ---------- DT-202 CDT ----------
def u16(data, pos):
    return data[pos] | (data[pos + 1] << 8)


def u32(data, pos):
    return (
        data[pos]
        | (data[pos + 1] << 8)
        | (data[pos + 2] << 16)
        | (data[pos + 3] << 24)
    )


def read_header(fp):
    fields = {}
    for i in range(1, 13):
        line = fp.readline()
        if not line.startswith(b'$'):
            raise ValueError(f'CDT 헤더 오류 line {i}')
        match = re.match(rb'\$(\d{2}),(.*)\*\r?\n?$', line, re.S)
        if not match:
            raise ValueError(f'CDT 헤더 형식 오류 line {i}')
        key = match.group(1).decode()
        fields[key] = (
            match.group(2).decode('cp949', 'replace')
            if key != '12'
            else match.group(2).hex()
        )
    model_firmware = fields.get('01', '')
    match = re.search(r'(DT-[A-Za-z0-9]+),([0-9.]+)', model_firmware)
    return {
        'vehicle_no': fields.get('04', '').strip(),
        'driver_code': fields.get('06', '').strip(),
        'model': match.group(1) if match else 'DT-202',
        'firmware': match.group(2) if match else 'unknown',
        'fields': fields,
    }


def decode_record(raw):
    recorded_at = DTG_EPOCH + timedelta(seconds=u32(raw, 0))
    speed = int(raw[24])
    rpm = min(u16(raw, 20), 9999)
    flags = int(raw[25])
    brake = bool(flags & 0x80 or raw[62] & 1)
    lon_i = u32(raw, 8)
    lat_i = u32(raw, 12)
    gps_valid = 124_000_000 < lon_i < 132_000_000 and 32_000_000 < lat_i < 39_000_000
    return {
        'dt': recorded_at,
        'speed': speed,
        'rpm': rpm,
        'brake': brake,
        'lon': lon_i / 1e6 if gps_valid else None,
        'lat': lat_i / 1e6 if gps_valid else None,
        'heading': u16(raw, 16) if gps_valid and u16(raw, 16) <= 360 else 0,
        'gps': gps_valid,
    }


def service_date_from_filename(path, fallback):
    match = re.match(r'(20\d{6})', Path(path).name)
    if match:
        try:
            return datetime.strptime(match.group(1), '%Y%m%d').date()
        except Exception:
            pass
    return fallback.date()


def parse_dt(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace('Z', '+00:00')).astimezone(KST)
    except Exception:
        return None


def normalize_vehicle(value):
    text = re.sub(r'\s+', '', str(value or ''))
    if re.fullmatch(r'\d{4}', text):
        return '경남71자' + text
    match = re.search(r'(?:경남)?\s*71\s*자?\s*(\d{4})$', text)
    if match:
        return '경남71자' + match.group(1)
    return text


def extract_vehicle(name):
    match = re.search(r'(경남\d{2}자\d{4})', name)
    return match.group(1) if match else ''


def group_contiguous_events(hits):
    buckets = defaultdict(list)
    for event in hits:
        key = (
            event.get('driver_name', ''),
            event.get('route_no', ''),
            event.get('run_order', -1),
            event.get('event_type', ''),
        )
        buckets[key].append(event)
    output = []
    for items in buckets.values():
        items = sorted(items, key=lambda item: item['recorded_at'])
        groups = []
        for event in items:
            if not groups or (
                event['recorded_at'] - groups[-1][-1]['recorded_at']
            ).total_seconds() != 1:
                groups.append([event])
            else:
                groups[-1].append(event)
        for group in groups:
            output.append(
                group[0]
                | {
                    'speed_after': group[-1]['speed_after'],
                    'evidence': {
                        **group[0].get('evidence', {}),
                        'duration_sec': len(group),
                    },
                }
            )
    return sorted(output, key=lambda item: item['recorded_at'])


def resolve_assignment(recorded_at, vehicle, dispatch, changes):
    current = recorded_at.replace(tzinfo=KST)
    direct = []
    for assignment in dispatch:
        if normalize_vehicle(assignment.get('vehicle_no')) != normalize_vehicle(vehicle):
            continue
        start = parse_dt(assignment.get('shift_start'))
        end = parse_dt(assignment.get('shift_end'))
        if start and end and start <= current <= end:
            direct.append(assignment)
    if direct:
        return direct[0]

    replacements = [
        change
        for change in changes
        if normalize_vehicle(change.get('new_vehicle')) == normalize_vehicle(vehicle)
        and parse_dt(change.get('detected_at'))
        and parse_dt(change.get('detected_at')) <= current
    ]
    if replacements:
        change = max(replacements, key=lambda item: parse_dt(item['detected_at']))
        return {
            'driver_name': change.get('driver_name', ''),
            'route_no': change.get('route_no', ''),
            'run_order': change.get('run_order', -1),
            'vehicle_no': vehicle,
            'shift_type': 'REPLACEMENT',
        }

    candidates = [
        assignment
        for assignment in dispatch
        if normalize_vehicle(assignment.get('vehicle_no')) == normalize_vehicle(vehicle)
    ]
    if candidates:
        shift_type = 'AM' if recorded_at.hour < 12 else 'PM'
        shifted = [item for item in candidates if item.get('shift_type') == shift_type]
        return (shifted or candidates)[0]
    return None


def active_dispatch_rows(rows, current_time=None):
    current_time = current_time or datetime.now(KST)
    output = []
    for assignment in rows:
        start = parse_dt(assignment.get('shift_start'))
        end = parse_dt(assignment.get('shift_end'))
        if start and end:
            if start <= current_time <= end:
                output.append(assignment)
            continue
        shift_type = str(assignment.get('shift_type') or '').upper()
        if shift_type == 'AM' and current_time.hour < 12:
            output.append(assignment)
        elif shift_type == 'PM' and current_time.hour >= 12:
            output.append(assignment)
        elif shift_type not in ('AM', 'PM'):
            output.append(assignment)
    return output


def analyze_cdt(path, cfg, dispatch, changes):
    file_path = Path(path)
    file_hash = sha256_file(file_path)
    records = []
    with file_path.open('rb') as fp:
        header = read_header(fp)
        while True:
            raw = fp.read(RECORD_SIZE)
            if not raw:
                break
            if len(raw) != RECORD_SIZE:
                raise ValueError('마지막 CDT 레코드 길이 오류')
            records.append(decode_record(raw))
    if not records:
        raise ValueError('CDT 운행레코드 없음')

    service_date = service_date_from_filename(file_path, records[0]['dt'])
    vehicle = normalize_vehicle(header['vehicle_no'] or extract_vehicle(file_path.name))
    hits = []
    summaries = defaultdict(
        lambda: {
            'distance_km': 0.0,
            'max_speed': 0,
            'rapid_start': 0,
            'rapid_accel': 0,
            'rapid_decel': 0,
            'rapid_stop': 0,
            'speed_watch': 0,
            'valid_pair_count': 0,
            'gap_seconds': 0,
        }
    )
    previous = None
    for record in records:
        assignment = resolve_assignment(record['dt'], vehicle, dispatch, changes)
        driver_name = assignment.get('driver_name', '') if assignment else ''
        route_no = str(assignment.get('route_no', '')) if assignment else ''
        run_order = assignment.get('run_order', -1) if assignment else -1
        key = (driver_name, route_no)
        if driver_name:
            summaries[key]['distance_km'] += record['speed'] / 3600
            summaries[key]['max_speed'] = max(summaries[key]['max_speed'], record['speed'])
            if record['speed'] >= cfg.get('speed_watch_kmh', 80):
                hits.append(
                    {
                        'event_type': 'speed_watch',
                        'recorded_at': record['dt'],
                        'speed_before': record['speed'],
                        'speed_after': record['speed'],
                        'brake_on': record['brake'],
                        'lat': record['lat'],
                        'lon': record['lon'],
                        'driver_name': driver_name,
                        'route_no': route_no,
                        'run_order': run_order,
                        'evidence': {
                            'speed_kmh': record['speed'],
                            'threshold_kmh': cfg.get('speed_watch_kmh', 80),
                        },
                    }
                )
        if previous:
            gap = (record['dt'] - previous['dt']).total_seconds()
            if driver_name and gap > 1:
                summaries[key]['gap_seconds'] += max(0, int(gap) - 1)
            if gap == 1:
                if driver_name:
                    summaries[key]['valid_pair_count'] += 1
                delta = record['speed'] - previous['speed']
                types = []
                if previous['speed'] <= 5 and delta >= 8:
                    types.append('rapid_start')
                if previous['speed'] >= 6 and delta >= 6:
                    types.append('rapid_accel')
                if record['speed'] >= 6 and delta <= -9:
                    types.append('rapid_decel')
                if record['speed'] <= 5 and delta <= -9:
                    types.append('rapid_stop')
                for event_type in types:
                    if driver_name:
                        hits.append(
                            {
                                'event_type': event_type,
                                'recorded_at': record['dt'],
                                'speed_before': previous['speed'],
                                'speed_after': record['speed'],
                                'brake_on': record['brake'],
                                'lat': record['lat'],
                                'lon': record['lon'],
                                'driver_name': driver_name,
                                'route_no': route_no,
                                'run_order': run_order,
                                'evidence': {'delta_kmh': delta},
                            }
                        )
        previous = record

    events = []
    for event in group_contiguous_events(hits):
        if event.get('driver_name'):
            key = (event['driver_name'], str(event.get('route_no', '')))
            if event['event_type'] in summaries[key]:
                summaries[key][event['event_type']] += 1
        timestamp = event['recorded_at'].replace(tzinfo=KST).isoformat()
        event_key = hashlib.sha1(
            f"{vehicle}|{timestamp}|{event['event_type']}|{event.get('driver_name','')}|{event.get('route_no','')}".encode()
        ).hexdigest()
        events.append(
            {
                'event_key': event_key,
                'service_date': service_date.isoformat(),
                'vehicle_no': vehicle,
                'driver_name': event['driver_name'],
                'route_no': event['route_no'],
                'run_order': event['run_order'],
                'recorded_at': timestamp,
                'event_type': event['event_type'],
                'severity': 'candidate',
                'speed_before': event['speed_before'],
                'speed_after': event['speed_after'],
                'brake_on': str(bool(event['brake_on'])).lower(),
                'latitude': event['lat'] if event['lat'] is not None else '',
                'longitude': event['lon'] if event['lon'] is not None else '',
                'criteria_version': 'LOCAL-CANDIDATE-v1',
                'evidence': event['evidence'],
            }
        )

    daily = []
    for (driver_name, route_no), values in summaries.items():
        if not driver_name:
            continue
        gap_seconds = values['gap_seconds']
        quality = 'good' if gap_seconds < 300 else ('review' if gap_seconds < 1800 else 'limited')
        daily.append(
            {
                'service_date': service_date.isoformat(),
                'driver_name': driver_name,
                'vehicle_no': vehicle,
                'route_no': route_no,
                'distance_km': round(values['distance_km'], 3),
                'max_speed': values['max_speed'],
                'rapid_start': values['rapid_start'],
                'rapid_accel': values['rapid_accel'],
                'rapid_decel': values['rapid_decel'],
                'rapid_stop': values['rapid_stop'],
                'speed_watch': values['speed_watch'],
                'valid_pair_count': values['valid_pair_count'],
                'gap_seconds': gap_seconds,
                'data_quality': quality,
            }
        )

    import_info = {
        'source_file': file_path.name,
        'source_path': str(file_path),
        'sha256': file_hash,
        'service_date': service_date.isoformat(),
        'vehicle_no': vehicle,
        'first_record_at': records[0]['dt'].replace(tzinfo=KST).isoformat(),
        'last_record_at': records[-1]['dt'].replace(tzinfo=KST).isoformat(),
        'record_count': len(records),
        'parser_version': VERSION,
    }
    return import_info, events, daily


# ---------- eTAS report auto import ----------
def powershell_excel_to_json(input_path: Path) -> list[dict]:
    """Read .xls/.xlsx through installed Microsoft Excel COM on Windows.

    eTAS official reports are separate monthly Excel files. They are automatically
    imported only after a downloaded file appears in the configured eTAS folder.
    """
    if os.name != 'nt':
        raise RuntimeError('eTAS 자동 Excel 읽기는 Windows에서만 지원합니다.')

    script = r'''
param([string]$InputPath,[string]$OutputPath)
$ErrorActionPreference = 'Stop'
$excel = $null
$book = $null
try {
  $excel = New-Object -ComObject Excel.Application
  $excel.Visible = $false
  $excel.DisplayAlerts = $false
  $book = $excel.Workbooks.Open($InputPath, 0, $true)
  $result = @()
  foreach ($sheet in $book.Worksheets) {
    $used = $sheet.UsedRange
    $rows = @()
    for ($r = 1; $r -le $used.Rows.Count; $r++) {
      $row = @()
      for ($c = 1; $c -le $used.Columns.Count; $c++) {
        $v = $used.Cells.Item($r,$c).Value2
        if ($null -eq $v) { $row += '' } else { $row += [string]$v }
      }
      $rows += ,$row
    }
    $result += [pscustomobject]@{ name = [string]$sheet.Name; rows = $rows }
  }
  $result | ConvertTo-Json -Depth 12 -Compress | Set-Content -Encoding UTF8 $OutputPath
}
finally {
  if ($null -ne $book) { $book.Close($false) | Out-Null }
  if ($null -ne $excel) { $excel.Quit() }
  if ($null -ne $book) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($book) }
  if ($null -ne $excel) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel) }
  [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}
'''
    with tempfile.TemporaryDirectory(prefix='daewoon_etas_') as temp_dir:
        temp = Path(temp_dir)
        ps_path = temp / 'read_excel.ps1'
        out_path = temp / 'workbook.json'
        ps_path.write_text(script, encoding='utf-8-sig')
        result = subprocess.run(
            [
                'powershell.exe',
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                str(ps_path),
                str(input_path.resolve()),
                str(out_path.resolve()),
            ],
            capture_output=True,
            text=True,
            timeout=180,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
        )
        if result.returncode != 0 or not out_path.exists():
            raise RuntimeError(
                'Microsoft Excel을 통한 eTAS 파일 읽기 실패: '
                + (result.stderr.strip() or result.stdout.strip() or '원인 미상')
            )
        data = json.loads(out_path.read_text(encoding='utf-8-sig'))
        return data if isinstance(data, list) else [data]


def parse_float(value):
    try:
        text = str(value or '').replace(',', '').strip()
        return float(text) if text else None
    except Exception:
        return None


def parse_etas_rows(rows: list[list], source_file: str) -> dict:
    flat = [str(cell or '') for row in rows for cell in row if str(cell or '').strip()]
    driver = ''
    level = ''
    analysis_month = ''
    summary = ''
    weekday = ''
    time_text = ''
    trend = ''

    for text in flat:
        match = re.search(r'(.+?)님의 안전운전 수준은\s*["“]?([^"”]+)["”]?', text)
        if match:
            driver = match.group(1).strip()
            level = match.group(2).replace('.', '').strip()
        month_match = re.search(r'(20\d{2})년\s*(\d{1,2})월', text)
        if month_match and not analysis_month:
            analysis_month = f"{month_match.group(1)}-{int(month_match.group(2)):02d}-01"
        if '안전운전수준은 업종평균대비' in text:
            summary = re.sub(r'^⊙\s*', '', text)
        if '위험운전행동은 특히' in text:
            weekday = re.sub(r'^⊙\s*', '', text)
            time_match = re.search(r'과\s*([^에]+)에 많이', text)
            if time_match:
                time_text = time_match.group(1).strip()
        if '월간 추이는' in text:
            trend = re.sub(r'^⊙\s*', '', text)

    for row in rows:
        for index, cell in enumerate(row):
            if '분석기간' in str(cell):
                for following in row[index + 1 :]:
                    match = re.search(r'(20\d{2})년\s*(\d{1,2})월', str(following or ''))
                    if match:
                        analysis_month = f"{match.group(1)}-{int(match.group(2)):02d}-01"
                        break

    behaviors = []
    header_row = -1
    for row_index, row in enumerate(rows):
        values = [str(cell or '').strip() for cell in row]
        if any(value == '구분' for value in values) and any('과속' in value for value in values):
            header_row = row_index
            break

    total_score = None
    if header_row >= 0:
        headers = []
        current = ''
        for cell in rows[header_row]:
            value = re.sub(r'\s+', '', str(cell or ''))
            if value:
                current = value
            headers.append(current)
        if header_row + 1 < len(rows):
            for column, cell in enumerate(rows[header_row + 1]):
                sub = re.sub(r'\s+', '', str(cell or ''))
                if sub and column < len(headers) and headers[column] == '급회전':
                    headers[column] = f'급회전-{sub}'

        data_rows = []
        for row in rows[header_row + 2 : header_row + 12]:
            label = ''
            for cell in row:
                value = str(cell or '').strip()
                if re.fullmatch(r'20\d{2}-\d{2}월', value) or value == '증감':
                    label = value
                    break
            if label:
                data_rows.append((label, row))

        current_row = None
        if analysis_month:
            key = analysis_month[:7]
            current_row = next((item for item in data_rows if item[0].startswith(key)), None)
        if current_row is None:
            actual = [item for item in data_rows if item[0] != '증감']
            current_row = actual[-1] if actual else None
        previous_candidates = [
            item for item in data_rows if item[0] != '증감' and item != current_row
        ]
        previous_row = previous_candidates[-1] if previous_candidates else None
        change_row = next((item for item in data_rows if item[0] == '증감'), None)

        if current_row:
            seen = set()
            for column, value in enumerate(current_row[1]):
                header = headers[column] if column < len(headers) else ''
                if not header or header in seen or header in ('합계', '구분'):
                    continue
                if str(value or '').strip() == '':
                    continue
                seen.add(header)
                behaviors.append(
                    {
                        'behavior': header,
                        'current_score': str(value),
                        'previous_score': (
                            str(previous_row[1][column])
                            if previous_row and column < len(previous_row[1])
                            else ''
                        ),
                        'change_score': (
                            str(change_row[1][column])
                            if change_row and column < len(change_row[1])
                            else ''
                        ),
                        'grade': '',
                    }
                )
            if '합계' in headers:
                total_index = headers.index('합계')
                if total_index < len(current_row[1]):
                    total_score = parse_float(current_row[1][total_index])

    recommendations = []
    for row_index, row in enumerate(rows):
        text = str(row[1] if len(row) > 1 else (row[0] if row else '')).strip()
        if re.match(r'^\d+\.\s*["“]', text):
            next_text = ''
            if row_index + 1 < len(rows):
                next_row = rows[row_index + 1]
                next_text = str(
                    next_row[1] if len(next_row) > 1 else (next_row[0] if next_row else '')
                ).strip()
            if next_text:
                recommendations.append({'title': text, 'text': next_text})

    if not driver:
        raise ValueError('eTAS 리포트에서 운전자명을 찾지 못했습니다.')
    if not analysis_month:
        analysis_month = datetime.now(KST).strftime('%Y-%m-01')

    return {
        'driver_name': driver,
        'analysis_month': analysis_month,
        'safety_level': level,
        'total_score': total_score,
        'summary_text': summary,
        'weekday_text': weekday,
        'time_text': time_text,
        'trend_text': trend,
        'recommendations': recommendations,
        'behaviors': behaviors,
        'source_file': source_file,
    }


# ---------- TAGO BIS ----------
class Tago:
    BASE_ROUTE = 'https://apis.data.go.kr/1613000/BusRouteInfoInqireService'
    BASE_LOC = 'https://apis.data.go.kr/1613000/BusLcInfoInqireService'

    def __init__(self, cfg):
        self.key = cfg.get('tago_service_key', '')
        self.city_code = cfg.get('city_code', '')
        self.city_name = cfg.get('city_name', '창원시')
        self.route_cache = {}

    def get(self, url, params):
        query = urllib.parse.urlencode(
            {**params, 'serviceKey': self.key, '_type': 'json'}, safe='%'
        )
        request = urllib.request.Request(
            url + '?' + query,
            headers={'User-Agent': 'DaewoonSafeDrive/1.1'},
        )
        with urllib.request.urlopen(request, timeout=25) as response:
            data = json.loads(response.read().decode('utf-8', 'replace'))
        response_header = (data.get('response') or {}).get('header') or {}
        result_code = str(response_header.get('resultCode') or '00')
        if result_code not in ('00', '0'):
            raise RuntimeError(
                f"TAGO 오류 {result_code}: {response_header.get('resultMsg', '응답 오류')}"
            )
        return data

    @staticmethod
    def items(data):
        items = (data.get('response') or {}).get('body', {}).get('items', {})
        if not items:
            return []
        value = items.get('item', []) if isinstance(items, dict) else []
        if isinstance(value, dict):
            return [value]
        return value or []

    def ensure_city(self):
        if self.city_code:
            return self.city_code
        data = self.get(self.BASE_ROUTE + '/getCtyCodeList', {'numOfRows': 300, 'pageNo': 1})
        for item in self.items(data):
            name = str(item.get('cityname') or item.get('cityName') or '')
            if self.city_name in name or name in self.city_name:
                self.city_code = str(item.get('citycode') or item.get('cityCode'))
                break
        if not self.city_code:
            raise RuntimeError(
                f'TAGO 도시코드에서 {self.city_name}을 찾지 못했습니다. '
                'collector_config.json의 city_code를 직접 입력하세요.'
            )
        log(f'TAGO 도시코드: {self.city_name}={self.city_code}')
        return self.city_code

    def route_id(self, route_no):
        route_key = str(route_no).strip()
        if route_key in self.route_cache:
            return self.route_cache[route_key]
        city = self.ensure_city()
        data = self.get(
            self.BASE_ROUTE + '/getRouteNoList',
            {
                'cityCode': city,
                'routeNo': route_key,
                'numOfRows': 100,
                'pageNo': 1,
            },
        )
        candidates = self.items(data)
        exact = [
            item
            for item in candidates
            if str(
                item.get('routeno')
                or item.get('routeNo')
                or item.get('routenum')
                or item.get('routenm')
                or ''
            ).strip()
            == route_key
        ]
        selected = (exact or candidates)[0] if (exact or candidates) else None
        if not selected:
            return None
        route_id = str(selected.get('routeid') or selected.get('routeId') or '')
        if route_id:
            self.route_cache[route_key] = route_id
        return route_id or None

    def locations(self, route_no):
        route_id = self.route_id(route_no)
        if not route_id:
            return []
        data = self.get(
            self.BASE_LOC + '/getRouteAcctoBusLcList',
            {
                'cityCode': self.ensure_city(),
                'routeId': route_id,
                'numOfRows': 300,
                'pageNo': 1,
            },
        )
        output = []
        for item in self.items(data):
            vehicle = normalize_vehicle(
                item.get('vehicleno') or item.get('vehicleNo') or ''
            )
            if not vehicle:
                continue
            try:
                node_order = int(item.get('nodeord') or item.get('nodeOrder') or 0)
            except Exception:
                node_order = 0
            output.append(
                {
                    'vehicle': vehicle,
                    'node_order': node_order,
                    'node_name': item.get('nodenm') or item.get('nodeName') or '',
                    'lat': item.get('gpslati') or item.get('gpsLati') or '',
                    'lon': item.get('gpslong') or item.get('gpsLong') or '',
                    'raw': item,
                }
            )
        return output


def infer_changes(route, expected_rows, live_rows, state, cfg, agent_id):
    today_key = datetime.now(KST).date().isoformat()
    route_state = (
        state.setdefault('bis_routes', {})
        .setdefault(today_key, {})
        .setdefault(str(route), {'last': {}, 'candidates': {}, 'replacements': {}})
    )

    original_expected = {
        normalize_vehicle(item.get('vehicle_no')): item
        for item in expected_rows
        if item.get('vehicle_no')
    }
    expected = dict(original_expected)
    for old_vehicle, new_vehicle in route_state.get('replacements', {}).items():
        if old_vehicle in expected:
            assignment = expected.pop(old_vehicle).copy()
            assignment['vehicle_no'] = new_vehicle
            expected[new_vehicle] = assignment

    live_map = {item['vehicle']: item for item in live_rows if item.get('vehicle')}
    now = datetime.now(KST)
    unexpected = [vehicle for vehicle in live_map if vehicle not in expected]
    missing = [vehicle for vehicle in expected if vehicle not in live_map]
    last = route_state.setdefault('last', {})
    recent_minutes = int(cfg.get('bis_recent_minutes', 12))
    pairs = []

    # 1) Best evidence: pair with the recently observed expected vehicle nearest by stop order.
    for new_vehicle in unexpected:
        new_location = live_map[new_vehicle]
        candidates = []
        for old_vehicle in missing:
            previous = last.get(old_vehicle)
            if not previous:
                continue
            try:
                age = (now - datetime.fromisoformat(previous['seen_at'])).total_seconds() / 60
            except Exception:
                continue
            if age <= recent_minutes:
                distance = abs(
                    int(previous.get('node_order', 0))
                    - int(new_location.get('node_order', 0))
                )
                candidates.append((distance, old_vehicle, 'high' if distance <= 3 else 'medium'))
        if candidates:
            distance, old_vehicle, confidence = min(candidates)
            pairs.append((old_vehicle, new_vehicle, distance, confidence))

    # 2) Collector may start after a replacement. A persistent 1:1 mismatch is still usable.
    if not pairs and len(unexpected) == 1 and len(missing) == 1:
        pairs = [(missing[0], unexpected[0], 99, 'medium')]

    # 3) Multiple persistent mismatches: low-confidence pairing by run order / current stop order.
    if not pairs and 1 < len(unexpected) == len(missing) <= 4:
        missing_sorted = sorted(
            missing,
            key=lambda vehicle: int(expected.get(vehicle, {}).get('run_order') or 9999),
        )
        unexpected_sorted = sorted(
            unexpected,
            key=lambda vehicle: int(live_map[vehicle].get('node_order') or 9999),
        )
        pairs = [
            (old_vehicle, new_vehicle, 999, 'low')
            for old_vehicle, new_vehicle in zip(missing_sorted, unexpected_sorted)
        ]

    observed_keys = set()
    results = []
    confirm_polls = max(2, int(cfg.get('bis_confirm_polls', 2)))
    for old_vehicle, new_vehicle, distance, confidence in pairs:
        pair_key = f'{old_vehicle}->{new_vehicle}'
        observed_keys.add(pair_key)
        candidate = route_state.setdefault('candidates', {}).setdefault(
            pair_key, {'count': 0, 'first_seen': now.isoformat()}
        )
        candidate['count'] = int(candidate.get('count', 0)) + 1
        candidate['last_seen'] = now.isoformat()
        if (
            candidate['count'] >= confirm_polls
            and old_vehicle not in route_state.get('replacements', {})
        ):
            assignment = original_expected.get(old_vehicle, expected.get(old_vehicle, {}))
            live = live_map[new_vehicle]
            detected_at = now.isoformat()
            change_key = hashlib.sha1(
                f'{today_key}|{route}|{old_vehicle}|{new_vehicle}'.encode()
            ).hexdigest()
            results.append(
                {
                    'change_key': change_key,
                    'service_date': today_key,
                    'route_no': str(route),
                    'run_order': assignment.get('run_order', -1),
                    'driver_name': assignment.get('driver_name', ''),
                    'old_vehicle': old_vehicle,
                    'new_vehicle': new_vehicle,
                    'detected_at': detected_at,
                    'node_order': live.get('node_order', ''),
                    'latitude': live.get('lat', ''),
                    'longitude': live.get('lon', ''),
                    'confidence': confidence,
                    'source': 'TAGO',
                    'collector_agent_id': agent_id,
                    'confirmed_polls': candidate['count'],
                    'raw': {
                        'node_name': live.get('node_name'),
                        'distance_node_order': distance,
                        'matching_method': (
                            'recent_node'
                            if distance != 99 and distance != 999
                            else ('persistent_1to1' if distance == 99 else 'ordered_multi')
                        ),
                    },
                }
            )
            route_state.setdefault('replacements', {})[old_vehicle] = new_vehicle
            log(
                f'BIS 차량변경 확정 노선 {route}: {old_vehicle} -> {new_vehicle} '
                f'({assignment.get("driver_name", "")}, {candidate["count"]}회 확인)'
            )

    # Candidate evidence must be continuous; stale candidates are reset.
    for key in list(route_state.get('candidates', {})):
        if key not in observed_keys:
            route_state['candidates'].pop(key, None)

    for vehicle, location in live_map.items():
        route_state.setdefault('last', {})[vehicle] = {
            'node_order': location['node_order'],
            'seen_at': now.isoformat(),
            'lat': location.get('lat'),
            'lon': location.get('lon'),
        }
    if len(route_state.get('last', {})) > 300:
        route_state['last'] = dict(list(route_state['last'].items())[-200:])
    return results, {
        'route': str(route),
        'expected': len(expected),
        'live': len(live_map),
        'missing': len(missing),
        'unexpected': len(unexpected),
        'pairs': len(pairs),
    }


class Collector:
    def __init__(self, cfg, service_mode=False):
        self.cfg = cfg
        self.service_mode = service_mode
        self.agent_id = cfg.get('agent_id') or socket.gethostname()
        self.cfg['agent_id'] = self.agent_id
        self.sb = Supabase(cfg)
        self.state = load_json(
            STATE_PATH,
            {'processed': {}, 'processed_etas': {}, 'bis_routes': {}},
        )
        self.stop_event = threading.Event()
        self.restart_requested = False
        self.tago = Tago(cfg)
        self.threads = []
        _RUNTIME['agent_id'] = self.agent_id
        _RUNTIME['config_summary'] = {
            'taco_folder': cfg.get('taco_folder'),
            'etas_folder': cfg.get('etas_folder'),
            'city_name': cfg.get('city_name'),
            'enable_taco': bool(cfg.get('enable_taco')),
            'enable_bis': bool(cfg.get('enable_bis')),
            'enable_etas_auto': bool(cfg.get('enable_etas_auto')),
            'bis_poll_seconds': int(cfg.get('bis_poll_seconds', 30)),
        }

    def remote_activity(self, category, message, level='info', detail=None):
        try:
            self.sb.activity(
                {
                    'agent_id': self.agent_id,
                    'category': category,
                    'level': level,
                    'message': message,
                    'detail': detail or {},
                }
            )
        except Exception:
            pass

    def update_heartbeat(self, status='running'):
        _RUNTIME['status'] = status
        write_status()
        payload = dict(_RUNTIME)
        payload['config_summary'] = _RUNTIME.get('config_summary', {})
        try:
            self.sb.heartbeat(payload)
        except Exception as exc:
            log(f'Heartbeat 전송 오류: {exc}', level='error')

    def handle_commands(self):
        try:
            commands = self.sb.fetch_commands(self.agent_id)
        except Exception as exc:
            log(f'Collector 명령 조회 오류: {exc}', level='error')
            return
        for command in commands:
            command_id = command.get('id')
            name = command.get('command')
            try:
                if name == 'reload':
                    self.sb.complete_command(command_id, True, '설정 재시작 요청을 수신했습니다.')
                    self.restart_requested = True
                    self.stop_event.set()
                elif name == 'restart':
                    self.sb.complete_command(command_id, True, 'Collector 재시작 요청을 수신했습니다.')
                    self.restart_requested = True
                    self.stop_event.set()
                elif name == 'stop':
                    self.sb.complete_command(command_id, True, 'Collector 종료 요청을 수신했습니다.')
                    self.stop_event.set()
                else:
                    self.sb.complete_command(command_id, False, '지원하지 않는 명령')
            except Exception as exc:
                try:
                    self.sb.complete_command(command_id, False, str(exc))
                except Exception:
                    pass

    def heartbeat_loop(self):
        seconds = max(10, int(self.cfg.get('heartbeat_seconds', 15)))
        while not self.stop_event.is_set():
            self.update_heartbeat('running')
            self.handle_commands()
            self.stop_event.wait(seconds)

    def login_with_retry(self):
        while not self.stop_event.is_set():
            try:
                self.sb.login()
                return
            except Exception as exc:
                log('Supabase 로그인 실패: ' + repr(exc), level='error')
                if not self.service_mode:
                    raise
                self.stop_event.wait(30)

    def run(self):
        self.login_with_retry()
        if self.stop_event.is_set():
            return
        _RUNTIME['status'] = 'running'
        log(f'{VERSION} 시작 / Agent={self.agent_id}')
        self.remote_activity('SYSTEM', f'{VERSION} 시작', detail={'pid': os.getpid()})

        heartbeat_thread = threading.Thread(target=self.heartbeat_loop, daemon=True)
        heartbeat_thread.start()
        self.threads.append(heartbeat_thread)

        if self.cfg.get('enable_bis') and self.cfg.get('tago_service_key'):
            thread = threading.Thread(target=self.bis_loop, daemon=True)
            thread.start()
            self.threads.append(thread)
        elif self.cfg.get('enable_bis'):
            log('BIS 감시는 활성화되어 있으나 TAGO 서비스키가 비어 있습니다.', level='error')

        if self.cfg.get('enable_taco'):
            thread = threading.Thread(target=self.taco_loop, daemon=True)
            thread.start()
            self.threads.append(thread)

        if self.cfg.get('enable_etas_auto'):
            thread = threading.Thread(target=self.etas_loop, daemon=True)
            thread.start()
            self.threads.append(thread)

        if len(self.threads) <= 1:
            log('활성화된 자료수집 기능이 없습니다.', level='error')

        try:
            while not self.stop_event.is_set():
                if STOP_PATH.exists():
                    try:
                        STOP_PATH.unlink()
                    except Exception:
                        pass
                    log('로컬 제어 프로그램의 종료 요청을 수신했습니다.')
                    self.stop_event.set()
                    break
                time.sleep(1)
        except KeyboardInterrupt:
            log('사용자 종료 요청')
            self.stop_event.set()
        finally:
            _RUNTIME['status'] = 'stopped'
            self.update_heartbeat('stopped')
            self.remote_activity('SYSTEM', 'Collector 종료')
            log('Collector 종료')

        if self.restart_requested:
            self.spawn_restart()

    def spawn_restart(self):
        try:
            args = [sys.executable, str(Path(__file__).resolve()), '--service']
            creation_flags = 0
            if os.name == 'nt':
                creation_flags = (
                    getattr(subprocess, 'DETACHED_PROCESS', 0)
                    | getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0)
                    | getattr(subprocess, 'CREATE_NO_WINDOW', 0)
                )
            subprocess.Popen(
                args,
                cwd=str(BASE_DIR),
                creationflags=creation_flags,
                close_fds=True,
            )
        except Exception as exc:
            log(f'자동 재시작 실패: {exc}', level='error')

    def taco_loop(self):
        folder = Path(self.cfg.get('taco_folder', DEFAULT_CONFIG['taco_folder']))
        log(f'타코/CDT 폴더 감시: {folder}')
        while not self.stop_event.is_set():
            _RUNTIME['last_taco_scan_at'] = now_iso()
            try:
                if folder.exists():
                    for path in sorted(folder.glob('*')):
                        if self.stop_event.is_set():
                            break
                        if path.is_file() and path.suffix.upper() == '.CDT':
                            self.process_cdt(path)
                else:
                    log(f'경고: 타코 폴더가 없습니다: {folder}', level='error')
            except Exception as exc:
                log('타코 감시 오류: ' + repr(exc), level='error')
            write_status()
            self.stop_event.wait(max(3, int(self.cfg.get('scan_seconds', 5))))

    def process_cdt(self, path):
        key = str(path.resolve())
        stat = path.stat()
        signature = f'{stat.st_size}:{int(stat.st_mtime)}'
        if self.state.setdefault('processed', {}).get(key) == signature:
            return
        self.stop_event.wait(float(self.cfg.get('stable_seconds', 8)))
        if self.stop_event.is_set():
            return
        stat_after = path.stat()
        if stat_after.st_size != stat.st_size:
            return
        try:
            with path.open('rb') as fp:
                read_header(fp)
                raw = fp.read(128)
                first = decode_record(raw) if len(raw) == 128 else None
            if not first:
                return
            service_date = service_date_from_filename(path, first['dt'])
            dispatch = self.sb.dispatch(service_date)
            changes = self.sb.changes(service_date)
            import_info, events, summaries = analyze_cdt(
                path, self.cfg, dispatch, changes
            )
            import_info['collector_agent_id'] = self.agent_id
            self.sb.ingest_taco(import_info, events, summaries)
            message = (
                f'CDT 수집 {path.name}: records={import_info["record_count"]}, '
                f'events={len(events)}, summaries={len(summaries)}'
            )
            log(message)
            self.remote_activity(
                'TACO',
                message,
                detail={
                    'file': path.name,
                    'records': import_info['record_count'],
                    'events': len(events),
                    'summaries': len(summaries),
                },
            )
            _RUNTIME['counters']['taco_files'] += 1
            _RUNTIME['counters']['taco_events'] += len(events)
            mark_success()
            self.state['processed'][key] = signature
            save_json(STATE_PATH, self.state)
        except Exception as exc:
            message = f'CDT 처리 실패 {path.name}: {exc}'
            log(message + '\n' + traceback.format_exc(), level='error')
            self.remote_activity('TACO', message, level='error')

    def etas_loop(self):
        folder = Path(self.cfg.get('etas_folder', DEFAULT_CONFIG['etas_folder']))
        try:
            folder.mkdir(parents=True, exist_ok=True)
        except Exception:
            pass
        log(f'eTAS 리포트 폴더 감시: {folder}')
        while not self.stop_event.is_set():
            _RUNTIME['last_etas_scan_at'] = now_iso()
            try:
                if folder.exists():
                    for path in sorted(folder.glob('*')):
                        if self.stop_event.is_set():
                            break
                        if path.is_file() and path.suffix.lower() in ('.xls', '.xlsx'):
                            self.process_etas(path)
                else:
                    log(f'경고: eTAS 폴더가 없습니다: {folder}', level='error')
            except Exception as exc:
                log('eTAS 감시 오류: ' + repr(exc), level='error')
            write_status()
            self.stop_event.wait(max(10, int(self.cfg.get('etas_scan_seconds', 20))))

    def process_etas(self, path):
        key = str(path.resolve())
        stat = path.stat()
        signature = f'{stat.st_size}:{int(stat.st_mtime)}'
        if self.state.setdefault('processed_etas', {}).get(key) == signature:
            return
        self.stop_event.wait(float(self.cfg.get('stable_seconds', 8)))
        if self.stop_event.is_set():
            return
        stat_after = path.stat()
        if stat_after.st_size != stat.st_size:
            return
        try:
            sheets = powershell_excel_to_json(path)
            reports = []
            for sheet in sheets:
                rows = sheet.get('rows') or []
                try:
                    report = parse_etas_rows(rows, path.name)
                    reports.append(report)
                    break
                except Exception:
                    continue
            if not reports:
                raise ValueError('eTAS 형식을 인식하지 못했습니다.')
            report = reports[0]
            report.update(
                {
                    'import_source': 'collector',
                    'source_sha256': sha256_file(path),
                    'source_path': str(path),
                    'collector_agent_id': self.agent_id,
                }
            )
            self.sb.import_etas(report)
            message = (
                f'eTAS 자동수집 {path.name}: {report["driver_name"]} / '
                f'{report["analysis_month"][:7]}'
            )
            log(message)
            self.remote_activity(
                'ETAS',
                message,
                detail={
                    'file': path.name,
                    'driver': report['driver_name'],
                    'month': report['analysis_month'],
                },
            )
            _RUNTIME['counters']['etas_files'] += 1
            mark_success()
            self.state['processed_etas'][key] = signature
            save_json(STATE_PATH, self.state)
        except Exception as exc:
            message = f'eTAS 처리 실패 {path.name}: {exc}'
            log(message, level='error')
            self.remote_activity('ETAS', message, level='error')
            # Keep it unprocessed so a corrected file or Excel installation can be retried.

    def bis_loop(self):
        log('BIS(TAGO) 차량변경 실시간 감시 시작')
        while not self.stop_event.is_set():
            _RUNTIME['last_bis_poll_at'] = now_iso()
            poll_summary = {
                'routes': 0,
                'expected': 0,
                'live': 0,
                'mismatches': 0,
                'changes': 0,
            }
            try:
                current = datetime.now(KST)
                today = current.date()
                rows = active_dispatch_rows(self.sb.dispatch(today), current)
                by_route = defaultdict(list)
                for assignment in rows:
                    route = str(assignment.get('route_no') or '').strip()
                    if route and route != '-1':
                        by_route[route].append(assignment)
                all_changes = []
                for route, expected_rows in by_route.items():
                    if self.stop_event.is_set():
                        break
                    try:
                        live = self.tago.locations(route)
                        changes, summary = infer_changes(
                            route,
                            expected_rows,
                            live,
                            self.state,
                            self.cfg,
                            self.agent_id,
                        )
                        all_changes.extend(changes)
                        poll_summary['routes'] += 1
                        poll_summary['expected'] += summary['expected']
                        poll_summary['live'] += summary['live']
                        poll_summary['mismatches'] += summary['pairs']
                        time.sleep(0.2)
                    except Exception as exc:
                        log(f'BIS 노선 {route} 조회 오류: {exc}', level='error')
                if all_changes:
                    result = self.sb.ingest_changes(all_changes)
                    poll_summary['changes'] = len(all_changes)
                    _RUNTIME['counters']['bis_changes'] += len(all_changes)
                    log(f'BIS 차량변경 저장: {result}')
                    self.remote_activity(
                        'BIS',
                        f'차량변경 {len(all_changes)}건 저장',
                        detail=poll_summary,
                    )
                    mark_success()
                _RUNTIME['counters']['bis_polls'] += 1
                _RUNTIME['counters']['last_bis_summary'] = poll_summary
                save_json(STATE_PATH, self.state)
            except Exception as exc:
                log('BIS 감시 오류: ' + repr(exc), level='error')
                self.remote_activity('BIS', str(exc), level='error')
            write_status()
            self.stop_event.wait(max(15, int(self.cfg.get('bis_poll_seconds', 30))))


def ensure_config():
    if not CONFIG_PATH.exists():
        save_json(CONFIG_PATH, DEFAULT_CONFIG)
        print(
            f'설정파일을 생성했습니다: {CONFIG_PATH}\n'
            '값을 입력한 후 다시 실행하세요.'
        )
        return None
    cfg = load_json(CONFIG_PATH, DEFAULT_CONFIG)
    missing = [
        key for key in ('supabase_url', 'supabase_anon_key') if not cfg.get(key)
    ]
    if missing:
        print('collector_config.json에 Supabase URL과 anon key를 입력하세요.')
        return None
    return {**DEFAULT_CONFIG, **cfg}


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument('--service', action='store_true', help='숨김 백그라운드 서비스 모드')
    args = parser.parse_args()
    acquire_single_instance()
    atexit.register(cleanup_instance)
    if STOP_PATH.exists():
        try:
            STOP_PATH.unlink()
        except Exception:
            pass
    cfg = ensure_config()
    if not cfg:
        return 2
    try:
        Collector(cfg, service_mode=args.service).run()
        return 0
    except Exception as exc:
        _RUNTIME['status'] = 'error'
        log('시작 실패: ' + repr(exc), level='error')
        write_status()
        if not args.service and sys.stdin and sys.stdin.isatty():
            try:
                input('Enter 키를 누르면 종료합니다...')
            except Exception:
                pass
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
