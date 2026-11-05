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

VERSION = 'DaewoonCollector-1.3.0'
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
    'scan_seconds': 5,
    'stable_seconds': 8,
    'heartbeat_seconds': 15,
    'tago_service_key': '',
    'city_code': '',
    'city_name': '창원시',
    'bis_poll_seconds': 30,
    'bis_confirm_polls': 2,
    'bis_recent_minutes': 12,
    'speed_watch_kmh': 80,
    'analysis_folder': r'E:\Choyoung\ADTviewer\SafeDriveAnalysis',
    'pending_retry_minutes': 60,
    'pending_retention_days': 180,
    'final_match_ratio': 0.90,
    'max_event_samples_per_type': 3,
    'bis_trip_window_minutes': 150,
    'event_retention_days': 90,
    'activity_retention_days': 30,
    'audit_retention_days': 180,
    'enable_bis': True,
    'enable_taco': True,
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
    'last_success_at': '',
    'last_error': '',
    'counters': {
        'taco_files': 0,
        'taco_events': 0,
        'bis_polls': 0,
        'bis_changes': 0,
        'pending_cdt': 0,
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

    def context(self, service_date: date):
        return self.rpc(
            'collector_get_context',
            {'p_token': self.token, 'p_service_date': service_date.isoformat()},
            timeout=60,
        ) or {'dispatch': [], 'bindings': [], 'timetable': [], 'day_type': ''}

    def cleanup_storage(self):
        return self.rpc(
            'collector_cleanup_minimal_storage',
            {
                'p_token': self.token,
                'p_event_days': int(self.cfg.get('event_retention_days', 90)),
                'p_activity_days': int(self.cfg.get('activity_retention_days', 30)),
                'p_audit_days': int(self.cfg.get('audit_retention_days', 180)),
            },
            timeout=60,
        )

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



def schedule_dt(service_date_value, departure_time):
    if not departure_time:
        return None
    try:
        text = str(departure_time)
        hh, mm, *rest = [int(part) for part in text.split(':')]
        ss = rest[0] if rest else 0
        return datetime(
            service_date_value.year,
            service_date_value.month,
            service_date_value.day,
            hh,
            mm,
            ss,
            tzinfo=KST,
        )
    except Exception:
        return None


def active_dispatch_rows(rows, timetable=None, current_time=None, trip_window_minutes=150):
    current_time = current_time or datetime.now(KST)
    timetable = timetable or []
    output = []
    schedule_map = defaultdict(list)
    for slot in timetable:
        route = str(slot.get('route_no') or '').strip()
        order = int(slot.get('run_order') or -1)
        dt_value = schedule_dt(current_time.date(), slot.get('departure_time'))
        if route and order > 0 and dt_value:
            schedule_map[(route, order)].append(dt_value)

    for assignment in rows:
        start = parse_dt(assignment.get('shift_start'))
        end = parse_dt(assignment.get('shift_end'))
        if start and end and not (start <= current_time <= end):
            continue
        if not start or not end:
            shift_type = str(assignment.get('shift_type') or '').upper()
            if shift_type == 'AM' and current_time.hour >= 14:
                continue
            if shift_type == 'PM' and current_time.hour < 10:
                continue

        route = str(assignment.get('route_no') or '').strip()
        order = int(assignment.get('run_order') or -1)
        slots = schedule_map.get((route, order), [])
        if slots:
            recent = [
                dt_value
                for dt_value in slots
                if 0 <= (current_time - dt_value).total_seconds() <= trip_window_minutes * 60
            ]
            upcoming = [
                dt_value
                for dt_value in slots
                if 0 < (dt_value - current_time).total_seconds() <= 20 * 60
            ]
            selected = max(recent) if recent else (min(upcoming) if upcoming else None)
            if selected is None:
                continue
            assignment = dict(assignment)
            assignment['_scheduled_departure'] = selected.isoformat()
        output.append(assignment)
    return output


def resolve_assignment(recorded_at, vehicle, dispatch, bindings):
    current = recorded_at.replace(tzinfo=KST)
    vehicle_norm = normalize_vehicle(vehicle)

    direct = []
    for assignment in dispatch:
        if normalize_vehicle(assignment.get('vehicle_no')) != vehicle_norm:
            continue
        start = parse_dt(assignment.get('shift_start'))
        end = parse_dt(assignment.get('shift_end'))
        if start and end and start <= current <= end:
            direct.append(assignment)
        elif not start or not end:
            shift_type = str(assignment.get('shift_type') or '').upper()
            if (shift_type == 'AM' and current.hour < 14) or (
                shift_type == 'PM' and current.hour >= 10
            ) or shift_type not in ('AM', 'PM'):
                direct.append(assignment)
    if direct:
        return sorted(
            direct,
            key=lambda item: (
                0 if item.get('shift_start') else 1,
                int(item.get('run_order') or 9999),
            ),
        )[0]

    matched_bindings = []
    for binding in bindings or []:
        if normalize_vehicle(
            binding.get('actual_vehicle') or binding.get('new_vehicle')
        ) != vehicle_norm:
            continue
        valid_from = parse_dt(
            binding.get('valid_from_at')
            or binding.get('effective_from_at')
            or binding.get('detected_at')
        )
        valid_to = parse_dt(binding.get('valid_to_at'))
        if valid_from and current < valid_from:
            continue
        if valid_to and current > valid_to:
            continue
        matched_bindings.append(binding)

    if matched_bindings:
        binding = max(
            matched_bindings,
            key=lambda item: parse_dt(
                item.get('valid_from_at')
                or item.get('effective_from_at')
                or item.get('detected_at')
            )
            or datetime.min.replace(tzinfo=KST),
        )
        return {
            'driver_name': binding.get('driver_name', ''),
            'route_no': binding.get('route_no', ''),
            'run_order': int(binding.get('run_order') or -1),
            'vehicle_no': vehicle_norm,
            'planned_vehicle': binding.get('planned_vehicle')
            or binding.get('old_vehicle'),
            'shift_type': 'ACTUAL_VEHICLE',
        }

    candidates = [
        assignment
        for assignment in dispatch
        if normalize_vehicle(assignment.get('vehicle_no')) == vehicle_norm
    ]
    if candidates:
        shift_type = 'AM' if current.hour < 14 else 'PM'
        shifted = [
            item
            for item in candidates
            if str(item.get('shift_type') or '').upper() == shift_type
        ]
        return (shifted or candidates)[0]
    return None


def build_safety_profile(values):
    distance = max(float(values.get('distance_km') or 0), 1.0)
    rates = {
        key: float(values.get(key) or 0) * 100.0 / distance
        for key in (
            'rapid_start',
            'rapid_accel',
            'rapid_decel',
            'rapid_stop',
            'speed_watch',
        )
    }
    penalty = (
        rates['rapid_start'] * 0.8
        + rates['rapid_accel'] * 0.8
        + rates['rapid_decel'] * 1.2
        + rates['rapid_stop'] * 1.6
        + rates['speed_watch'] * 0.5
    )
    score = round(max(0.0, 100.0 - min(100.0, penalty)), 1)
    if score >= 95:
        level = '매우양호'
    elif score >= 90:
        level = '양호'
    elif score >= 80:
        level = '주의'
    else:
        level = '개선필요'

    ranked = sorted(rates.items(), key=lambda item: item[1], reverse=True)
    labels = {
        'rapid_start': '급출발',
        'rapid_accel': '급가속',
        'rapid_decel': '급감속',
        'rapid_stop': '급정지',
        'speed_watch': '관리속도 초과',
    }
    top = [labels[key] for key, value in ranked if value > 0][:2]
    if top:
        analysis_text = (
            f"운행거리 {float(values.get('distance_km') or 0):.1f}km 기준 "
            f"{', '.join(top)} 패턴을 우선 점검할 필요가 있습니다."
        )
    else:
        analysis_text = (
            f"운행거리 {float(values.get('distance_km') or 0):.1f}km에서 "
            '주요 위험운전 후보가 확인되지 않았습니다.'
        )
    recommendations = []
    if rates['rapid_start'] or rates['rapid_accel']:
        recommendations.append('출발·재가속 시 단계적으로 가속하여 승차감을 확보합니다.')
    if rates['rapid_decel'] or rates['rapid_stop']:
        recommendations.append('정류장·교차로 접근 전에 미리 감속하여 급제동을 줄입니다.')
    if rates['speed_watch']:
        recommendations.append('노선별 제한속도와 회사 관리속도를 준수합니다.')
    if not recommendations:
        recommendations.append('현재의 부드러운 운전패턴을 지속 유지합니다.')
    return score, level, rates, analysis_text, recommendations


def analyze_cdt(path, cfg, context):
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
    dispatch = context.get('dispatch') or []
    bindings = context.get('bindings') or context.get('changes') or []
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
            'matched_seconds': 0,
            'unmatched_seconds': 0,
            'event_samples': defaultdict(list),
            'run_orders': set(),
        }
    )
    total_matched = 0
    total_unmatched = 0
    previous = None
    previous_assignment = None

    for record in records:
        assignment = resolve_assignment(record['dt'], vehicle, dispatch, bindings)
        driver_name = assignment.get('driver_name', '') if assignment else ''
        route_no = str(assignment.get('route_no', '')) if assignment else ''
        run_order = int(assignment.get('run_order') or -1) if assignment else -1
        key = (driver_name, route_no)
        if driver_name:
            total_matched += 1
            summaries[key]['matched_seconds'] += 1
            summaries[key]['run_orders'].add(run_order)
            summaries[key]['distance_km'] += record['speed'] / 3600
            summaries[key]['max_speed'] = max(
                summaries[key]['max_speed'], record['speed']
            )
            if record['speed'] >= int(cfg.get('speed_watch_kmh', 80)):
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
                            'threshold_kmh': int(cfg.get('speed_watch_kmh', 80)),
                        },
                    }
                )
        else:
            total_unmatched += 1

        if previous:
            gap = (record['dt'] - previous['dt']).total_seconds()
            if driver_name and gap > 1:
                summaries[key]['gap_seconds'] += max(0, int(gap) - 1)
            same_driver = (
                driver_name
                and previous_assignment
                and previous_assignment.get('driver_name') == driver_name
                and str(previous_assignment.get('route_no', '')) == route_no
            )
            if gap == 1 and same_driver:
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
        previous_assignment = assignment

    grouped = group_contiguous_events(hits)
    events = []
    max_samples = max(1, int(cfg.get('max_event_samples_per_type', 3)))
    sample_counter = defaultdict(int)
    for event in grouped:
        key = (event['driver_name'], str(event.get('route_no', '')))
        if event['event_type'] in summaries[key]:
            summaries[key][event['event_type']] += 1
        timestamp = event['recorded_at'].replace(tzinfo=KST).isoformat()
        sample = {
            'event_type': event['event_type'],
            'recorded_at': timestamp,
            'speed_before': event['speed_before'],
            'speed_after': event['speed_after'],
            'brake_on': bool(event['brake_on']),
            'latitude': event['lat'],
            'longitude': event['lon'],
            'run_order': event.get('run_order', -1),
            'evidence': event.get('evidence', {}),
        }
        summaries[key]['event_samples'][event['event_type']].append(sample)
        sample_key = (
            event['driver_name'],
            str(event.get('route_no', '')),
            event['event_type'],
        )
        if sample_counter[sample_key] >= max_samples:
            continue
        sample_counter[sample_key] += 1
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
                'criteria_version': 'SAFEDRIVE-CANDIDATE-v2',
                'evidence': event['evidence'],
            }
        )

    total_records = max(1, len(records))
    match_ratio = total_matched / total_records
    if total_matched == 0:
        match_status = 'pending'
    elif match_ratio >= float(cfg.get('final_match_ratio', 0.90)):
        match_status = 'matched'
    else:
        match_status = 'partial'
    late_days = max(0, (datetime.now(KST).date() - service_date).days)

    daily = []
    for (driver_name, route_no), values in summaries.items():
        if not driver_name:
            continue
        gap_seconds = values['gap_seconds']
        quality = 'good' if gap_seconds < 300 else (
            'review' if gap_seconds < 1800 else 'limited'
        )
        score, level, rates, analysis_text, recommendations = build_safety_profile(
            values
        )
        samples = {
            event_type: sample_rows[:max_samples]
            for event_type, sample_rows in values['event_samples'].items()
        }
        daily.append(
            {
                'service_date': service_date.isoformat(),
                'driver_name': driver_name,
                'vehicle_no': vehicle,
                'route_no': route_no,
                'run_order': min(
                    [value for value in values['run_orders'] if value > 0],
                    default=-1,
                ),
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
                'match_status': match_status,
                'matched_seconds': values['matched_seconds'],
                'unmatched_seconds': total_unmatched,
                'late_days': late_days,
                'safety_score': score,
                'safety_level': level,
                'event_rates': rates,
                'event_samples': samples,
                'analysis_text': analysis_text,
                'recommendations': recommendations,
            }
        )

    import_info = {
        'source_file': file_path.name,
        'source_path': '',
        'sha256': file_hash,
        'service_date': service_date.isoformat(),
        'vehicle_no': vehicle,
        'first_record_at': records[0]['dt'].replace(tzinfo=KST).isoformat(),
        'last_record_at': records[-1]['dt'].replace(tzinfo=KST).isoformat(),
        'record_count': len(records),
        'parser_version': VERSION,
        'collected_at': now_iso(),
        'delay_days': late_days,
        'match_status': match_status,
        'matched_seconds': total_matched,
        'unmatched_seconds': total_unmatched,
        'summary_only': True,
    }
    return import_info, events, daily


def write_local_analysis(cfg, import_info, events, summaries):
    root = Path(cfg.get('analysis_folder') or (BASE_DIR / 'analysis_archive'))
    service_date = str(import_info.get('service_date') or 'unknown')
    folder = root / service_date[:4] / service_date[5:7]
    folder.mkdir(parents=True, exist_ok=True)
    short_hash = str(import_info.get('sha256') or '')[:12]
    vehicle = normalize_vehicle(import_info.get('vehicle_no'))
    target = folder / f'{service_date}_{vehicle}_{short_hash}.json'
    payload = {
        'import': import_info,
        'summaries': summaries,
        'event_samples': events,
        'note': '원본 CDT는 업로드하지 않으며 이 파일은 회사 PC의 로컬 분석 근거자료입니다.',
    }
    save_json(target, payload)
    try:
        return str(target.relative_to(root))
    except Exception:
        return target.name




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
            headers={'User-Agent': 'DaewoonSafeDrive/1.3'},
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
            assignment['_planned_vehicle'] = assignment.get('_planned_vehicle') or old_vehicle
            assignment['vehicle_no'] = new_vehicle
            expected[new_vehicle] = assignment

    live_map = {item['vehicle']: item for item in live_rows if item.get('vehicle')}
    now = datetime.now(KST)
    unexpected = [vehicle for vehicle in live_map if vehicle not in expected]
    missing = [vehicle for vehicle in expected if vehicle not in live_map]
    last = route_state.setdefault('last', {})
    recent_minutes = int(cfg.get('bis_recent_minutes', 12))
    pairs = []

    # 1) Best evidence: globally pair recently observed expected vehicles with
    # unexpected live vehicles by nearest stop order, without duplicate pairing.
    recent_pairs = []
    for new_vehicle in unexpected:
        new_location = live_map[new_vehicle]
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
                recent_pairs.append(
                    (distance, old_vehicle, new_vehicle, 'high' if distance <= 3 else 'medium')
                )
    used_old = set()
    used_new = set()
    for distance, old_vehicle, new_vehicle, confidence in sorted(recent_pairs):
        if old_vehicle in used_old or new_vehicle in used_new:
            continue
        pairs.append((old_vehicle, new_vehicle, distance, confidence))
        used_old.add(old_vehicle)
        used_new.add(new_vehicle)

    remaining_missing = [v for v in missing if v not in used_old]
    remaining_unexpected = [v for v in unexpected if v not in used_new]

    # 2) Collector may start after a replacement. A persistent 1:1 mismatch is usable.
    if len(remaining_unexpected) == 1 and len(remaining_missing) == 1:
        pairs.append((remaining_missing[0], remaining_unexpected[0], 99, 'medium'))
        used_old.add(remaining_missing[0])
        used_new.add(remaining_unexpected[0])
        remaining_missing = []
        remaining_unexpected = []

    # 3) Multiple start substitutions: pair the earlier scheduled trip with the bus
    # that has progressed farther along the route. This is retained as low confidence
    # and requires repeated observations before becoming a binding.
    if 1 < len(remaining_unexpected) == len(remaining_missing) <= 8:
        def assignment_time(vehicle):
            assignment = expected.get(vehicle, {})
            return parse_dt(assignment.get('_scheduled_departure')) or parse_dt(
                assignment.get('shift_start')
            ) or datetime.max.replace(tzinfo=KST)

        missing_sorted = sorted(remaining_missing, key=assignment_time)
        unexpected_sorted = sorted(
            remaining_unexpected,
            key=lambda vehicle: int(live_map[vehicle].get('node_order') or -1),
            reverse=True,
        )
        pairs.extend(
            (old_vehicle, new_vehicle, 999, 'low')
            for old_vehicle, new_vehicle in zip(missing_sorted, unexpected_sorted)
        )

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
            previous_old = last.get(old_vehicle)
            change_type = 'MID_ROUTE' if previous_old else 'START_SUBSTITUTE'
            scheduled = parse_dt(assignment.get('_scheduled_departure'))
            shift_start = parse_dt(assignment.get('shift_start'))
            effective_from = (
                now
                if change_type == 'MID_ROUTE'
                else (scheduled or shift_start or now)
            )
            valid_to = parse_dt(assignment.get('shift_end'))
            change_key = hashlib.sha1(
                f'{today_key}|{route}|{assignment.get("run_order",-1)}|{old_vehicle}|{new_vehicle}'.encode()
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
                    'planned_vehicle': assignment.get('_planned_vehicle') or old_vehicle,
                    'actual_vehicle': new_vehicle,
                    'change_type': change_type,
                    'effective_from_at': effective_from.isoformat(),
                    'valid_to_at': valid_to.isoformat() if valid_to else '',
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
                        'scheduled_departure': assignment.get('_scheduled_departure'),
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
        # This is a short-lived diagnostic snapshot only. It is overwritten on
        # every poll and is not uploaded as a full BIS position history.
        'expected_vehicles': sorted(expected.keys()),
        'live_vehicles': sorted(live_map.keys()),
        'missing_vehicles': sorted(missing),
        'unexpected_vehicles': sorted(unexpected),
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
            {'processed': {}, 'pending_cdt': {}, 'bis_routes': {}, 'last_cleanup_date': ''},
        )
        self.state.setdefault('processed', {})
        self.state.setdefault('pending_cdt', {})
        self.state.setdefault('bis_routes', {})
        self.stop_event = threading.Event()
        self.restart_requested = False
        self.tago = Tago(cfg)
        self.threads = []
        _RUNTIME['agent_id'] = self.agent_id
        _RUNTIME['config_summary'] = {
            'taco_folder': cfg.get('taco_folder'),
            'analysis_folder': cfg.get('analysis_folder'),
            'city_name': cfg.get('city_name'),
            'enable_taco': bool(cfg.get('enable_taco')),
            'enable_bis': bool(cfg.get('enable_bis')),
            'bis_poll_seconds': int(cfg.get('bis_poll_seconds', 30)),
            'pending_retry_minutes': int(cfg.get('pending_retry_minutes', 60)),
            'storage_mode': 'summary_only',
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
            if str(_RUNTIME.get('last_error') or '').startswith('Collector 명령 조회 오류'):
                _RUNTIME['last_error'] = ''
                write_status()
        except Exception as exc:
            # Remote control failure must not stop BIS/CDT collection.
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
        _RUNTIME['counters']['pending_cdt'] = len(self.state.get('pending_cdt', {}))
        log(f'{VERSION} 시작 / Agent={self.agent_id}')
        self.remote_activity(
            'SYSTEM',
            f'{VERSION} 시작',
            detail={
                'pid': os.getpid(),
                'storage_mode': 'summary_only',
                'pending_cdt': len(self.state.get('pending_cdt', {})),
            },
        )

        try:
            today_key = datetime.now(KST).date().isoformat()
            if self.state.get('last_cleanup_date') != today_key:
                result = self.sb.cleanup_storage()
                self.state['last_cleanup_date'] = today_key
                save_json(STATE_PATH, self.state)
                log(f'Supabase 최소저장 정리 완료: {result}')
        except Exception as exc:
            log(f'저장공간 정리 오류: {exc}', level='error')

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

        pending = self.state.setdefault('pending_cdt', {}).get(key)
        if pending and pending.get('signature') == signature:
            next_retry = parse_dt(pending.get('next_retry_at'))
            if next_retry and datetime.now(KST) < next_retry:
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
            context = self.sb.context(service_date)
            import_info, events, summaries = analyze_cdt(path, self.cfg, context)
            import_info['collector_agent_id'] = self.agent_id
            archive_ref = write_local_analysis(
                self.cfg, import_info, events, summaries
            )
            import_info['local_archive_ref'] = archive_ref
            result = self.sb.ingest_taco(import_info, events, summaries)

            status = import_info.get('match_status', 'pending')
            message = (
                f'CDT 분석 {path.name}: 운행일={import_info["service_date"]}, '
                f'수집지연={import_info.get("delay_days", 0)}일, '
                f'상태={status}, matched={import_info.get("matched_seconds",0)}초, '
                f'unmatched={import_info.get("unmatched_seconds",0)}초, '
                f'summaries={len(summaries)}, samples={len(events)}'
            )
            log(message)
            self.remote_activity(
                'TACO',
                message,
                detail={
                    'file': path.name,
                    'service_date': import_info['service_date'],
                    'delay_days': import_info.get('delay_days', 0),
                    'match_status': status,
                    'records': import_info['record_count'],
                    'event_samples': len(events),
                    'summaries': len(summaries),
                    'archive_ref': archive_ref,
                    'db_result': result,
                },
            )
            _RUNTIME['counters']['taco_files'] += 1
            _RUNTIME['counters']['taco_events'] += len(events)
            mark_success()

            if status == 'matched':
                self.state['processed'][key] = signature
                self.state['pending_cdt'].pop(key, None)
            else:
                retry_minutes = max(
                    10, int(self.cfg.get('pending_retry_minutes', 60))
                )
                first_pending = (
                    pending.get('first_pending_at')
                    if pending
                    else now_iso()
                )
                age_days = max(
                    0,
                    (
                        datetime.now(KST).date()
                        - service_date
                    ).days,
                )
                if age_days > int(
                    self.cfg.get('pending_retention_days', 180)
                ):
                    self.state['processed'][key] = signature
                    self.state['pending_cdt'].pop(key, None)
                    log(
                        f'CDT 매칭대기 보존기간 종료: {path.name} '
                        f'({age_days}일 경과, 마지막 상태={status})',
                        level='error',
                    )
                else:
                    self.state['pending_cdt'][key] = {
                        'signature': signature,
                        'service_date': service_date.isoformat(),
                        'vehicle_no': import_info.get('vehicle_no'),
                        'match_status': status,
                        'first_pending_at': first_pending,
                        'last_attempt_at': now_iso(),
                        'next_retry_at': (
                            datetime.now(KST)
                            + timedelta(minutes=retry_minutes)
                        ).isoformat(),
                    }
            _RUNTIME['counters']['pending_cdt'] = len(
                self.state.get('pending_cdt', {})
            )
            save_json(STATE_PATH, self.state)
        except Exception as exc:
            message = f'CDT 처리 실패 {path.name}: {exc}'
            log(message + '\n' + traceback.format_exc(), level='error')
            self.remote_activity('TACO', message, level='error')

    def bis_loop(self):
        log('BIS(TAGO) 실제 운행차량 감시 시작')
        while not self.stop_event.is_set():
            _RUNTIME['last_bis_poll_at'] = now_iso()
            poll_summary = {
                'routes': 0,
                'expected': 0,
                'live': 0,
                'mismatches': 0,
                'changes': 0,
                'route_details': [],
            }
            try:
                current = datetime.now(KST)
                today = current.date()
                context = self.sb.context(today)
                rows = active_dispatch_rows(
                    context.get('dispatch') or [],
                    context.get('timetable') or [],
                    current,
                    int(self.cfg.get('bis_trip_window_minutes', 150)),
                )
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
                        if len(poll_summary['route_details']) < 30:
                            poll_summary['route_details'].append(summary)
                        time.sleep(0.2)
                    except Exception as exc:
                        log(f'BIS 노선 {route} 조회 오류: {exc}', level='error')

                if all_changes:
                    result = self.sb.ingest_changes(all_changes)
                    poll_summary['changes'] = len(all_changes)
                    _RUNTIME['counters']['bis_changes'] += len(all_changes)
                    log(f'BIS 실제차량 연결 저장: {result}')
                    self.remote_activity(
                        'BIS',
                        f'실제차량 연결 {len(all_changes)}건 저장',
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
            self.stop_event.wait(
                max(15, int(self.cfg.get('bis_poll_seconds', 30)))
            )


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
