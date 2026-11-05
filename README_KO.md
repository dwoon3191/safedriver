# 대운교통 SafeDrive AI v1.3.0

## 1. 사용 목적

SafeDrive AI는 일일 배차표와 노선별 운행시간표로 예정 운행을 구성하고, TAGO/BIS로 실제 운행차량을 확인한 뒤, 차량 입고 후 수집되는 CDT를 실제 기사에게 연결하여 기사별 운전습관을 분석·피드백하는 시스템입니다.

```text
배차표 + 운행시간표 -> 예정 기사·차량·노선·회차
                     -> TAGO/BIS 실제차량 확인
                     -> 차량교체·대체차량 유효구간 저장
                     -> 늦게 도착한 CDT를 실제 기사에게 재연결
                     -> 2026-10-01 이후 일·월별 운전습관 분석
                     -> 관리자 검토 및 기사 본인 확인
```

SafeDrive의 위험운전 이벤트와 점수는 회사 내부 안전교육·코칭용 참고자료이며 교통안전공단 공식점수 또는 법규 위반 확정자료가 아닙니다.

## 2. v1.3.0 핵심 변경

- Collector 원격명령 SQL 오류 수정
- `SafeDrive_Collector_Control.bat` 한 개로 설정·진단·자동실행·시작·종료 통합
- 노선별 예정차량·BIS 실제차량·누락차량·추가차량 표시
- 관리자 웹의 `데이터 연계` 화면 추가
- 관리자 최초 기기 로그인 시 URL·publishable/anon key 확인·등록
- 기사 로그인에는 URL·API 입력 없음
- 기사별 로그인 횟수·누적 사용시간·최근 활동·온라인 여부 추가
- 기사 분석기간을 2026-10-01부터 월 단위로 관리
- CDT 지연수집과 Supabase 최소저장 정책 유지

## 3. 자료별 역할과 저장범위

| 자료 | 목적 | 등록/수집 | Supabase 저장범위 |
|---|---|---|---|
| 일일 배차표 | 기사와 예정차량 확인 | Excel 다중 업로드 | 배차 연결정보 |
| 노선별 운행시간표 | 노선·순번·출발시간·요일구분 | Excel 버전 업로드 | 시간표 슬롯 |
| TAGO/BIS | 실제 운행차량과 교체 확인 | Collector 주기조회 | 확정 실제차량·변경 이벤트만 |
| CDT/TACO | 속도·브레이크·GPS 기반 분석 | 지정 폴더 자동감시 | 파일 메타·기사별 집계·대표사건만 |

전체 BIS 위치 스트림과 CDT 1초 전체 레코드는 Supabase에 저장하지 않습니다.

## 4. 관리자와 기사 로그인

### 관리자
- 최초 관리자로 로그인하는 컴퓨터·휴대전화에서 Supabase URL과 publishable/anon key를 확인·등록
- 이후 배차·시간표·BIS·CDT 연계상태, 기사 분석, 접속현황을 관리

### 기사
- ID: 본인 이름
- 초기 비밀번호: `1111`
- 첫 로그인 후 비밀번호 변경
- URL·API key 입력 없음
- 본인 분석자료와 코칭내용만 조회

기사 설정 없는 로그인을 위해 운영 Netlify 루트에는 관리자가 생성한 `config.js`가 있어야 합니다. 배포 ZIP에는 운영값 보호를 위해 `config.js`를 포함하지 않습니다.

> URL과 publishable/anon key 자체가 권한보안 수단은 아닙니다. 실제 보안은 DB 함수·역할·행 접근통제로 적용되며 service_role/secret key를 브라우저에 넣으면 안 됩니다.

## 5. Collector 설치·운영

Collector 폴더에서 사용자가 실행할 파일은 하나입니다.

```text
SafeDrive_Collector_Control.bat
```

통합 제어센터에서 다음을 수행합니다.

- 환경설정 저장
- Supabase·TAGO·CDT 폴더 연결진단
- Windows 자동실행 설치/제거
- 수집 시작·종료·재시작
- 마지막 CDT/BIS 처리시각 확인
- 노선별 예정/BIS 실제차량 비교 확인
- 로그·웹앱 열기

제어센터를 닫아도 Collector 백그라운드 예약작업은 계속 실행됩니다. `collector_config.json`과 `collector_state.json`은 업데이트 또는 시작·종료 과정에서 초기화하지 않습니다.

## 6. 신규 설치

1. Supabase 프로젝트 생성
2. `sql/01_schema.sql` 전체 실행
3. 웹앱에서 `관리자 / 1111` 로그인 후 비밀번호 변경
4. 관리자 설정화면에서 URL과 publishable/anon key 등록
5. 생성한 `config.js`를 Netlify 웹 루트에 배포
6. GitHub Push 및 Netlify 배포
7. 회사 PC에 Python 3.10 이상 설치
8. `collector/SafeDrive_Collector_Control.bat` 실행
9. 환경설정 탭에 Supabase·관리자·TAGO·CDT 폴더 입력 후 저장
10. 연결진단 실행
11. 자동실행 설치 후 수집 시작
12. 관리자 웹의 `수집현황`과 `데이터 연계`에서 확인

## 7. 기존 v1.2.0 갱신

1. `config.js`, `collector_config.json`, `collector_state.json` 백업
2. Supabase에서 `sql/07_collector_usage_monthly_fix.sql` 1회 실행
3. 웹의 `index.html`, `assets/`, `netlify.toml` 교체
4. Collector 코드 폴더를 교체하되 기존 설정·상태파일을 다시 복사
5. `SafeDrive_Collector_Control.bat` 실행
6. 연결진단 후 자동실행 재설치·재시작
7. 관리자 웹에서 2026-10-01 이후 월별 분석 및 연계상태 확인

## 8. Collector 기본 설정

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

## 9. 관리자 화면 확인순서

1. `일일 배차표`: 기사·예정차량·노선·순번 확인
2. `노선별 운행시간표`: 적용버전과 평일/주말/공휴일 시간 확인
3. `수집현황`: Collector 온라인 및 노선별 BIS 비교 확인
4. `데이터 연계`: 배차 → 시간표 → BIS 실제차량 → CDT → 기사분석 단계별 건수 확인
5. `기사 운행분석`: 2026-10-01 이후 일별·월별 점수와 이벤트/100km 확인
6. `기사 계정`: 로그인 횟수·누적 사용시간·최근 활동 확인

로그인 횟수와 사용시간은 v1.3.0 SQL 적용 이후부터 집계되며 과거 접속시간은 소급 복원되지 않습니다.

## 10. 보안 및 운영 주의

- `collector_config.json`, `config.js`, API key, 비밀번호를 공개 저장소에 올리지 않음
- service_role/secret key를 웹과 Collector에 사용하지 않음
- 화면 캡처에 노출된 비밀번호와 API key는 운영 전 변경 권장
- 기사별 결과는 처벌 자동결정이 아니라 관리자 검토 후 코칭에 활용
- 차량변경 0건이면 `수집현황`의 노선별 비교와 `데이터 연계`의 배차·시간표·BIS 단계부터 점검
