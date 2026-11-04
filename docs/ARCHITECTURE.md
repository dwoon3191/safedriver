# SafeDrive AI v1.2.0 시스템 구조

## 목적
기사별 실제 운행차량을 확정하고 CDT 운행기록을 해당 기사에게 연결하여 안전운전 피드백을 제공한다.

## 논리 구조

```text
[관리자 웹]
  ├─ 기사 근무/배차 Excel 다중 업로드
  ├─ 일일 노선·운행순위 XLS/XLSX/CSV 다중 업로드
  ├─ 노선별 시간표 Excel 버전 업로드
  └─ 공휴일·특수일 지정
             │
             ▼
[Supabase 기준정보]
  배차 / 시간표 / 달력예외 / 기사계정
             ▲
             │
[Windows Collector] ── TAGO 노선·위치 API
  │                       │
  │                       └─ 전체 위치 미저장
  ├─ 예정차량과 실제차량 비교
  ├─ 출발 전 대체/중간교체 확정
  ├─ 실제차량 유효구간 저장
  └─ CDT 폴더 감시
             │
             ▼
[CDT 지연수집 재매칭]
  운행일 → 실제차량 유효구간 → 기사·노선·회차
             │
             ▼
[SafeDrive 분석]
  일일 집계 / 대표 이벤트 / 내부점수 / 코칭
             │
             ▼
[관리자·기사 웹]
  관리자 검토 / 기사 확인 / 확인현황
```

## Supabase 최소 테이블
- app_users, app_sessions
- dispatch_assignments
- route_timetable_versions, route_timetable_slots
- service_calendar_overrides
- vehicle_change_events, trip_vehicle_bindings
- taco_imports, taco_driver_daily, taco_events(대표 건만)
- driver_publications, driver_acknowledgements
- collector_agents, collector_activity_logs, collector_commands

## 로컬 PC 보존
- 원본 CDT
- `collector_config.json`
- `collector_state.json`
- `collector.log`
- `SafeDriveAnalysis/YYYY/MM/*.json` 요약 근거자료

## 식별 및 매칭 우선순위
1. CDT 차량과 동일한 배차차량 + 시간구간
2. BIS 실제차량 바인딩 + 유효시각
3. 차량·AM/PM fallback
4. 미확정이면 pending/partial로 저장하고 재시도

## 차량변경 판정
- TAGO 노선별 실시간 차량목록 조회
- 적용 시간표로 현재 운행 가능한 회차만 선별
- 예정차량 누락 + 예상 외 차량 출현 비교
- 최근 정류소 순서, 출발시각 진행도, 반복 관측 사용
- 2회 이상 반복 확인 후 저장
- START_SUBSTITUTE: 시작부터 다른 차량
- MID_ROUTE: 운행 중 차량 변경
