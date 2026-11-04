# 대운교통 SafeDrive AI v1.1.0

배차표, CDT/TACO, 창원 BIS(TAGO), 교통안전공단 eTAS를 연계해 기사별 안전운행 결과를 제공하는 신규 웹서비스입니다.

## v1.1.0 주요 변경

1. **배차표 다중 업로드 강화**
   - 일자별 `.xls/.xlsx` 여러 파일 동시 선택
   - 모든 시트와 상단 50행에서 헤더 자동 탐색
   - `20261104_배차.xls`처럼 파일명에서 운행일자 인식
   - 4자리 차량번호는 `경남71자####` 형식으로 표준화
   - 파일별 인식건수·실패사유·운행일자 미리보기

2. **eTAS 자동·수동 수집 분리**
   - CDT/TACO: `E:\Choyoung\ADTviewer\Data` 자동 감시
   - eTAS: 공단에서 내려받은 월간 Excel을 `etas_folder`에 저장하면 자동 등록
   - 웹에서도 여러 eTAS 리포트 수동 등록 가능
   - 자동/수동 수집방식, 파일명, 등록시각, 기사 확인 여부 조회

3. **BIS 차량변경 감지 보강**
   - 배차표 예정차량과 TAGO 실제 운행차량을 기본 30초마다 비교
   - Collector 시작 이전에 이미 교체된 1:1 차량 불일치도 반복 확인 후 감지
   - 여러 차량 불일치 시 운행순위·정류소 순서 기반 저신뢰 후보 검토
   - 전체 위치자료는 저장하지 않고 확정된 차량변경 이벤트만 저장
   - 웹에서 마지막 BIS 조회시각, 조회노선, 불일치 후보, Collector 상태 확인

4. **관리자 기사별 통합 리포트**
   - 기사별 eTAS 공식점수와 CDT 자체 후보분석을 구분하여 조회
   - 운전자별 분석월, 안전수준, 행동점수, 종합진단, 기사 확인시각 확인

5. **백그라운드 Collector 및 제어센터**
   - `pythonw.exe + Windows 예약작업`으로 CMD 창 없이 계속 실행
   - `collector_control.bat`에서 시작·종료·재시작·설정·로그·웹앱 열기
   - 제어창을 닫아도 수집은 계속됨
   - 로컬 상태파일과 Supabase heartbeat를 이용해 재실행 후 상태 확인
   - 웹 관리자 메뉴 `수집현황`에서 CDT/BIS/eTAS 실시간 수집상태 확인

6. **고품격 시작 화면**
   - AI 교통관제·안전분석 콘셉트의 SafeDrive 전용 배경 적용

---

## 중요: 자료 종류의 차이

| 자료 | 생성·수집 방식 | 용도 |
|---|---|---|
| 배차표 | 관리자가 일자별 Excel 다중 업로드 | 차량·기사·노선·운행시간 기준자료 |
| BIS/TAGO | Collector가 실시간 API 조회 | 배차차량과 실제 운행차량 비교, 차량교체 확인 |
| CDT/TACO | ADTviewer Data 폴더 자동 감시 | 속도·브레이크·GPS 기반 자체 후보분석 |
| eTAS 공식 리포트 | 공단에서 Excel 다운로드 후 감시폴더 자동 등록 또는 웹 수동 등록 | 공단 공식 안전수준·점수·진단·권고문 |

**eTAS는 CDT 파일에서 직접 생성되는 자료가 아닙니다.** 공단 사이트에서 내려받은 리포트 파일이 있어야 자동 등록할 수 있습니다.

---

## 1. 기존 Supabase 프로젝트 업그레이드

이미 v1.0.4를 사용 중이라면 Supabase SQL Editor에서 다음 파일을 **한 번만 전체 실행**합니다.

```text
sql/05_operational_monitor_upgrade.sql
```

이 SQL은 기존 배차·기사·CDT·eTAS 데이터를 삭제하지 않습니다. Collector 상태, 수집활동, 명령, 기사별 관리자 리포트 기능을 추가합니다.

배차표 저장 timeout 수정 SQL을 아직 실행하지 않았다면 먼저 다음 파일을 실행합니다.

```text
sql/04_dispatch_import_timeout_fix.sql
```

신규 Supabase 프로젝트는 `sql/01_schema.sql` 전체를 실행하면 됩니다.

---

## 2. GitHub / Netlify 배포

프로젝트 루트의 다음 파일과 폴더를 GitHub 저장소에 반영합니다.

```text
index.html
assets/
netlify.toml
```

`config.js`는 사용하지 않으며 최종 ZIP에도 포함되어 있지 않습니다. 웹 첫 실행 시 Supabase URL과 publishable/anon key를 입력합니다.

배포 후 브라우저에서 `Ctrl + F5`로 새로고침합니다.

---

## 3. Collector 설정 및 백그라운드 설치

### 3-1. Python 설치

Python 3.10 이상을 설치하고 설치 화면에서 **Add Python to PATH**를 선택합니다.

### 3-2. 설정파일 생성

```text
collector/setup_windows.bat
```

을 실행하면 `collector_config.json`이 생성되고 메모장으로 열립니다.

### 3-3. 설정 예시

```json
{
  "supabase_url": "https://xxxx.supabase.co",
  "supabase_anon_key": "Supabase publishable 또는 anon key",
  "login_id": "관리자",
  "password": "웹앱에서 변경한 관리자 비밀번호",
  "agent_id": "DAEWOON-OFFICE-01",
  "web_url": "https://dwoondriver.netlify.app",
  "taco_folder": "E:\\Choyoung\\ADTviewer\\Data",
  "etas_folder": "E:\\Choyoung\\ADTviewer\\eTAS",
  "tago_service_key": "공공데이터포털 일반 인증키",
  "city_code": "",
  "city_name": "창원시",
  "bis_poll_seconds": 30,
  "bis_confirm_polls": 2,
  "enable_bis": true,
  "enable_taco": true,
  "enable_etas_auto": true
}
```

- `login_id` 항목명은 영어 그대로 유지합니다.
- 실제 값은 웹 관리자 ID인 `관리자`로 입력합니다.
- `password`에는 웹앱에서 현재 정상 로그인되는 변경 비밀번호를 입력합니다.
- TAGO 인증키는 한 칸에 한 개만 입력합니다. 같은 키로 노선정보·위치정보 API 권한을 사용합니다.
- `city_code`는 비워두면 창원시를 자동 조회합니다.

### 3-4. 백그라운드 설치

다음 파일을 마우스 오른쪽 버튼으로 눌러 **관리자 권한으로 실행**합니다.

```text
collector/install_autostart_task.bat
```

설치 후 Collector가 CMD 창 없이 시작됩니다.

### 3-5. 제어센터

```text
collector/collector_control.bat
```

기능:

- 수집 시작
- 수집 종료
- 재시작
- 설정 열기
- 로그 열기
- 웹앱 열기
- CDT/BIS/eTAS 마지막 수집시각 및 오류 확인

제어센터 창을 닫아도 Windows 예약작업의 Collector는 계속 실행됩니다.

진단 목적으로 콘솔 메시지를 확인해야 할 때만 `start_collector.bat`를 사용합니다.

---

## 4. eTAS 자동수집 방법

1. 교통안전공단 eTAS에서 `리포트 다운로드t.xls` 형식의 보고서를 내려받습니다.
2. 다운로드 파일을 `collector_config.json`의 `etas_folder` 폴더에 저장합니다.
3. Collector가 파일이 더 이상 변경되지 않는 것을 확인한 뒤 읽습니다.
4. Microsoft Excel이 설치된 Windows PC에서는 Excel COM을 이용하여 `.xls/.xlsx`를 해석합니다.
5. 운전자명·분석월·안전수준·행동점수·진단·권고문을 Supabase에 등록하고 기사에게 다시 공개합니다.
6. 관리자는 `eTAS 리포트`, `기사별 리포트`, `수집현황` 메뉴에서 결과를 확인합니다.

Excel이 설치되지 않았거나 자동 인식에 실패하면 웹의 `eTAS 리포트` 메뉴에서 수동 업로드할 수 있습니다.

---

## 5. 배차표 다중 업로드

1. 관리자 로그인
2. `배차표 관리`
3. 여러 날짜의 배차 Excel 파일을 동시에 선택
4. 파일별 인식건수와 날짜 확인
5. `Supabase에 저장` 클릭

운행일자 셀이 없더라도 파일명이 `YYYYMMDD_배차.xls`이면 해당 날짜를 사용합니다.

---

## 6. BIS 차량변경 확인

Collector가 다음 순서로 처리합니다.

```text
배차표 노선번호
→ TAGO 노선정보에서 routeId 조회
→ TAGO 버스위치정보에서 실제 차량번호 조회
→ 배차표 예정차량과 비교
→ 동일 불일치를 2회 이상 확인
→ 차량변경 이벤트만 Supabase 저장
```

관리자 웹의 `차량변경` 메뉴에서 다음을 확인할 수 있습니다.

- 마지막 BIS 조회시각
- Collector 온라인 여부
- 조회 노선 수
- 불일치 후보 수
- 배차차량 → 실제차량 변경내역
- 반복 확인 횟수와 신뢰도

---

## 7. 보안 주의사항

다음 파일은 GitHub에 올리지 않습니다.

```text
collector/collector_config.json
collector/collector_state.json
collector/collector_status.json
collector/collector.log
collector/collector.pid
```

공공데이터포털 인증키, Supabase key, 관리자 비밀번호는 회사 PC의 `collector_config.json`에만 보관합니다.

실제 배차표와 eTAS 리포트에는 개인정보가 포함될 수 있으므로 샘플 파일도 공개 GitHub 저장소에 등록하지 않는 것을 권장합니다.
