# 대운교통 SafeDrive AI v1.2.0

## 1. 시스템 목적

SafeDrive AI는 버스기사별 실제 운행차량과 운행기록을 정확히 연결하여 개인별 운행습관을 분석하고, 관리자 검토 후 기사 본인에게 안전운전 피드백을 제공하는 웹서비스입니다.

핵심 목적은 다음과 같습니다.

1. 일일 배차표로 기사와 예정 차량을 확인
2. 노선별·운행순위별 시간표로 회차와 운행시각을 확인
3. TAGO/BIS로 출발 전 대체차량과 운행 중 차량교체를 확인
4. 차량 입고 후 생성되는 CDT를 실제 운행일·기사·실제차량에 재연결
5. 교통안전공단 보고서의 구성방식을 참고한 SafeDrive 내부 분석 리포트 제공
6. 기사가 본인의 결과를 확인하고, 관리자가 확인 여부를 조회

SafeDrive 점수와 위험운전 후보는 회사 내부 분석결과이며 교통안전공단의 공식 점수나 위반 확정자료가 아닙니다.

## 2. 자료별 역할

| 자료 | 역할 | 수집/등록 방식 | Supabase 저장범위 |
|---|---|---|---|
| 기사 근무·배차표 | 누가 어느 차량을 운전했는지 확인 | Excel 다중 업로드 | 배차 연결정보 |
| 일일 노선·운행순위 자료 | 차량별 노선·순번·AM/PM 출발시각 보완 | XLS/XLSX/CSV 다중 업로드 | 배차에 병합된 정보 |
| 노선별 운행시간표 | 평일·토요일·일/공휴일 회차 기준 | Excel 다중·버전 업로드 | 시간표 슬롯 |
| TAGO/BIS | 실제 운행차량, 출발 전 대체 및 중간 교체 확인 | Collector 실시간 조회 | 확정된 실제차량 연결/변경만 |
| CDT/타코 | 속도·브레이크·GPS·시각 기반 운행습관 분석 | 회사 PC 폴더 자동감시 | 파일 메타·기사별 일일집계·대표 이벤트만 |

BIS 전체 위치이력과 CDT 원본 1초 레코드는 Supabase에 업로드하지 않습니다.

## 3. 실제차량 결정 흐름

```text
기사 근무표 + 일일 노선/순위 자료 + 적용 시간표
                         ↓
               예정 기사·차량·노선·회차
                         ↓
               TAGO/BIS 실제 운행차량 비교
                         ↓
       예정차량 그대로 / 출발 전 대체 / 운행 중 교체
                         ↓
           기사·노선·회차별 실제차량 유효구간 저장
                         ↓
        나중에 도착한 CDT를 시각구간별 실제 기사에 재연결
```

예: 1172호로 배차되었지만 동일 노선·회차·시간에 1188호가 반복 확인되면, 1188호를 실제 운행차량으로 저장합니다. 이후 1188호 CDT가 며칠 뒤 생성되더라도 해당 기사 운행기록에 포함합니다.

## 4. 지연 수집 CDT 처리

CDT는 차량 입고나 수리 후 며칠 뒤 생성될 수 있습니다. Collector는 파일 수집일이 아니라 다음 순서로 운행일을 결정합니다.

1. 파일명의 YYYYMMDD 확인
2. 파일명에 날짜가 없으면 첫 운행레코드 시각 사용
3. 해당 운행일의 배차·시간표·BIS 실제차량 연결정보 조회
4. 1초 레코드를 기사·노선·회차에 재매칭
5. 매칭정보가 부족하면 pending/partial 상태로 보존
6. 기준정보가 보완되면 일정 주기로 자동 재분석

기본 재시도 주기는 60분, 매칭대기 보존기간은 180일입니다.

## 5. 관리자와 기사 기능

### 관리자
- Supabase URL·anon/publishable key 최초 설정
- 배차표 다중 업로드
- 노선 운행시간표 버전 관리
- 공휴일·특수 운행일 지정
- BIS 실제차량/차량교체 확인
- 기사별 SafeDrive 분석리포트 조회
- 기사 결과 확인여부 조회
- Collector 온라인 상태·지연수집·오류 확인
- 기사 계정 및 비밀번호 초기화

### 기사
- ID: 본인 이름
- 초기 비밀번호: 1111
- 첫 로그인 후 비밀번호 의무 변경
- Supabase URL/key 입력 없음
- 본인 운행분석, 배차·차량교체 이력, 코칭내용 확인
- ‘확인했습니다’ 처리

기사 휴대전화에서 설정 없이 로그인하려면 관리자가 생성한 `config.js`를 웹앱 루트에 배포해야 합니다. 업데이트 ZIP에는 `config.js`를 포함하지 않아 운영값이 덮어쓰이지 않습니다.

## 6. 최소저장 정책

Supabase 저장용량을 보호하기 위해 다음 정책을 적용합니다.

### 저장하는 자료
- 배차와 시간표 기준정보
- 공휴일/특수일 지정정보
- BIS에서 확정된 실제차량 연결과 차량변경
- CDT 파일명·해시·차량·운행일·레코드수·수집지연일
- 기사별 일일 거리·최고속도·위험운전 후보 건수·내부점수·코칭
- 위험유형별 대표 이벤트 최대 3건
- 기사 확인여부, Collector 상태, 제한된 기간의 작업로그

### 저장하지 않는 자료
- CDT 원본파일
- CDT 1초 전체 레코드
- TAGO/BIS 전체 위치 스트림
- 원본 Excel 파일 자체
- API 서비스키·관리자 비밀번호

대표 이벤트는 기본 90일, Collector 활동로그는 30일, 감사로그는 180일 경과 시 정리합니다.

## 7. 설치 요약

### 신규 설치
1. Supabase 새 프로젝트 생성
2. `sql/01_schema.sql` 전체 실행
3. 웹앱에서 관리자/1111 로그인 후 비밀번호 변경
4. 설정/설치 메뉴에서 URL과 anon/publishable key 입력
5. `config.js` 생성 후 웹앱 루트에 배포
6. GitHub Push 및 Netlify 배포
7. 회사 PC에 Python 3.10 이상 설치
8. `collector/setup_windows.bat` 실행
9. `collector_config.json` 입력
10. `install_autostart_task.bat` 관리자 권한 실행
11. `collector_control.bat`에서 상태 확인

### 기존 v1.1.0 갱신
1. `config.js`, `collector_config.json`, `collector_state.json` 백업
2. Supabase에서 `sql/06_delayed_taco_minimal_storage.sql` 1회 실행
3. 웹파일 `index.html`, `assets/`, `netlify.toml` 교체
4. Collector 실행파일만 교체하고 설정·상태 파일은 유지
5. 예약작업 재등록 후 제어센터에서 재시작

v1.0.4 이하에서 직접 갱신하는 경우 `05_operational_monitor_upgrade.sql` 실행 후 `06_delayed_taco_minimal_storage.sql`을 실행합니다.

## 8. Collector 설정

```json
{
  "supabase_url": "https://YOUR_PROJECT.supabase.co",
  "supabase_anon_key": "YOUR_PUBLISHABLE_OR_ANON_KEY",
  "login_id": "관리자",
  "password": "변경한 관리자 비밀번호",
  "agent_id": "DAEWOON-OFFICE-01",
  "web_url": "https://dwoondriver.netlify.app",
  "taco_folder": "E:\\Choyoung\\ADTviewer\\Data",
  "analysis_folder": "E:\\Choyoung\\ADTviewer\\SafeDriveAnalysis",
  "tago_service_key": "공공데이터포털 일반 인증키",
  "city_code": "",
  "city_name": "창원시",
  "bis_poll_seconds": 30,
  "bis_confirm_polls": 2,
  "speed_watch_kmh": 80,
  "pending_retry_minutes": 60,
  "pending_retention_days": 180,
  "enable_bis": true,
  "enable_taco": true
}
```

- `bis_poll_seconds`: BIS 조회주기(초)
- `bis_confirm_polls`: 동일 불일치가 연속 확인되어야 하는 횟수
- `speed_watch_kmh`: 회사 내부 관리속도 초과 후보 기준
- `collector_config.json`과 `collector_state.json`은 업데이트·시작·종료 시 자동 초기화하지 않습니다.

## 9. 배차와 시간표 업로드

### 일일 배차표
기사 근무파일과 일일 노선·운행순위 파일을 같은 업로드 화면에서 여러 개 선택합니다. 시스템은 `운행일+차량+AM/PM`을 기준으로 기사자료에 노선·순번·출발시각을 보완합니다.

### 노선 운행시간표
- 평일/토요일/일·공휴일 블록 자동 인식
- 일반/방학/임시·특별 버전 등록
- 적용시작일·종료일 관리
- ‘순번’ 열을 자동 탐색하여 시트 구조 차이를 처리
- 평일의 공휴일은 ‘공휴일·특수 운행일 지정’에서 HOLIDAY로 등록

## 10. 분석과 점수

분석항목:
- 급출발 후보
- 급가속 후보
- 급감속 후보
- 급정지 후보
- 회사 관리속도 초과 후보
- 100km당 발생률
- 일·월별 변화추이

점수는 SafeDrive 내부 참고점수입니다. 실제 교통상황, 승객안전 확보를 위한 불가피한 제동, 데이터 누락을 고려하여 관리자가 원본 근거를 확인한 후 코칭에 활용해야 합니다.

## 11. 보안 주의사항

- `config.js`에는 공개 가능한 Supabase anon/publishable key만 사용
- service_role key 사용 금지
- `collector_config.json`은 GitHub/Netlify 업로드 금지
- TAGO 서비스키와 관리자 비밀번호는 회사 수집 PC에만 보관
- 기사에게는 본인 자료만 제공
- 위험운전 후보를 자동 징계나 법규 위반 확정에 사용하지 않음
