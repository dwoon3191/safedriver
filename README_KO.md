## Windows Collector v1.0.2 배치파일 수정

Windows CMD에서 한글/UTF-8 배치파일이 깨지는 문제를 방지하기 위해 다음 파일을 **ASCII + CRLF + BOM 없음**으로 다시 작성했습니다.

- `collector/setup_windows.bat`
- `collector/start_collector.bat`
- `collector/install_autostart_task.bat`
- `collector/remove_autostart_task.bat`

권장 실행 순서:
1. Python 3.10 이상 설치 (`Add Python to PATH` 체크)
2. `setup_windows.bat` 실행
3. 자동으로 열리는 `collector_config.json` 저장
4. `start_collector.bat`로 수동 동작 확인
5. 정상 수집 확인 후 `install_autostart_task.bat`를 **관리자 권한**으로 실행

> v1.0.1 패키지에는 BAT 파일이 누락된 문제가 있었으며 v1.0.2에서 포함·수정했습니다.

# 대운교통 SafeDrive NEW v1.0

대운교통(주)의 **배차표 + CDT(타코) + 창원 BIS/TAGO + 교통안전공단 eTAS 리포트**를 연결해 기사별 안전운행 분석 결과를 제공하는 웹앱입니다.

## 1. 이번 버전의 핵심

- 기사 로그인 ID = **본인 이름**
- 기사 초기 비밀번호 = **1111**, 첫 로그인 후 변경 강제
- 배차표 `.xls/.xlsx` 업로드 및 기사 계정 자동 생성
- `E:\Choyoung\ADTviewer\Data` 폴더의 DT-202 `.CDT` 자동 감시·분석
- BIS 실시간 차량 위치를 이용한 **운행 중 차량교체 후보 탐지**
- BIS 원본 스냅샷은 DB에 쌓지 않고 **차량변경 이벤트만 Supabase 저장**
- 교통안전공단 `리포트 다운로드t.xls` 업로드 → 기사별 eTAS 점수/수준/권고문 저장
- 기사 본인 휴대전화에서 본인 분석자료만 확인
- 기사 `확인했습니다` 버튼 → 관리자가 확인 여부/시각 조회
- GitHub 버전관리 / Netlify 정적 웹서비스 / Supabase 데이터베이스

> **중요:** eTAS에서 가져온 공단 점수와 CDT 1초 속도차분으로 계산한 자체 후보 이벤트는 서로 다른 데이터입니다. 화면과 DB에서 분리 관리합니다.

---

## 2. 폴더 구조

```text
Daewoon_SafeDrive_NEW/
├─ index.html
├─ config.js                     # Supabase URL + anon/publishable key
├─ netlify.toml
├─ assets/
│  ├─ app.css
│  └─ app.js
├─ sql/
│  └─ 01_schema.sql              # Supabase 전체 DB/RPC 설치
├─ collector/
│  ├─ daewoon_collector.py       # Windows 자동수집기
│  ├─ collector_config.example.json
│  ├─ setup_windows.bat
│  ├─ start_collector.bat
│  └─ install_autostart_task.bat
├─ samples/                      # 사용자가 제공한 샘플 원본
└─ docs/
```

---

# 3. Supabase 설치

### STEP 1. Supabase 프로젝트 생성

Supabase에서 새 프로젝트를 만듭니다.

### STEP 2. SQL 실행

1. Supabase → **SQL Editor**
2. `sql/01_schema.sql` 전체 복사
3. Run 실행

설치되는 주요 데이터:

- 사용자 / 세션 / 작업이력
- 배차표
- 차량변경 이벤트
- CDT 수집이력 / 후보 이벤트 / 기사별 일일요약
- eTAS 리포트 / 위험행동 점수
- 기사 분석자료 공개 / 확인여부

초기 관리자:

```text
ID: 관리자
PW: 1111
```

처음 로그인하면 새 비밀번호로 변경해야 합니다.

### STEP 3. URL과 Key 입력

Supabase Project Settings → API에서 다음 두 값만 준비합니다.

```text
Project URL
Publishable key 또는 anon key
```

`config.js`에 넣어도 되고, 처음 웹앱 실행 시 화면에서 입력해도 됩니다.

```javascript
window.DAEWOON_CONFIG = {
  SUPABASE_URL: "https://xxxx.supabase.co",
  SUPABASE_ANON_KEY: "eyJ..."
};
```

**service_role key는 브라우저에 절대 넣지 않습니다.**

---

# 4. GitHub + Netlify 배포

### GitHub Desktop

1. 이 폴더 전체를 GitHub 저장소 폴더로 사용
2. GitHub Desktop → Add existing repository 또는 Create repository
3. Commit
4. Push origin

### Netlify

1. Netlify → Add new site → Import an existing project
2. GitHub 저장소 선택
3. Build command: 비워둠
4. Publish directory: `.`
5. Deploy

배포 후 `index.html`이 자동 시작됩니다.

---

# 5. 배차표 업로드

관리자 로그인 → **배차표 관리**

샘플에서 확인된 두 형식을 자동 인식합니다.

### 형식 A: 근무시간 배차표

```text
번호 / 차량번호 / 운전자이름 / 근무시작일자 / 근무시작시간 / 근무종료일자 / 근무종료시간
```

### 형식 B: 노선 배차표

```text
업체명 / 운행일자 / 차량번호 / 노선명 / 운행순위 / 지원노선명 / 지원운행순위 / 오전승무원명 / 오후승무원명
```

배차표를 업로드하면 기사 이름을 기준으로 계정을 자동 생성합니다.

```text
로그인 ID = 기사 이름
초기 비밀번호 = 1111
```

기존 계정의 비밀번호는 배차표 재업로드 시 초기화하지 않습니다.

---

# 6. 교통안전공단 eTAS 리포트 업로드

관리자 → **eTAS 리포트** → `리포트 다운로드t.xls` 선택

샘플에서 다음 항목을 읽도록 구성했습니다.

- 기사 이름
- 분석월
- 안전운전 수준
- 종합 진단결과
- 요일/시간대 특성
- 월간/주간 추이
- 위험운전행동 점수
  - 과속
  - 장기과속
  - 급가속
  - 급출발
  - 급감속
  - 급정지
  - 급회전(좌/우/U턴)
  - 급앞지르기
  - 급진로변경
- 종합 권고문

업로드 즉시 기사에게 분석자료가 공개되고, 기사는 모바일에서 `확인했습니다`를 누를 수 있습니다.

---

# 7. 회사 PC 자동수집기 설치

Netlify 웹사이트는 브라우저 보안 때문에 Windows의

```text
E:\Choyoung\ADTviewer\Data
```

폴더를 직접 감시할 수 없습니다.

따라서 해당 PC에서 `collector`가 실행됩니다.

### 설치

1. Python 3.10 이상 설치
2. `collector/setup_windows.bat` 실행
3. 생성된 `collector_config.json` 입력
4. `start_collector.bat` 실행

외부 Python 패키지는 필요하지 않습니다.

### 설정 예

```json
{
  "supabase_url": "https://xxxx.supabase.co",
  "supabase_anon_key": "eyJ...",
  "login_id": "관리자",
  "password": "관리자가 변경한 비밀번호",
  "taco_folder": "E:\\Choyoung\\ADTviewer\\Data",
  "tago_service_key": "공공데이터포털 서비스키",
  "city_code": "",
  "city_name": "창원시",
  "bis_poll_seconds": 60,
  "speed_watch_kmh": 80
}
```

`city_code`를 비우면 TAGO 도시코드 목록에서 창원시를 찾습니다. 자동 조회가 되지 않으면 공공데이터포털에서 확인한 도시코드를 직접 입력합니다.

### Windows 로그인 시 자동 시작

`install_autostart_task.bat`를 관리자 권한으로 실행합니다.

---

# 8. CDT 자동분석

현재 수집기는 DT-202 CDT 샘플에서 확인된 다음 데이터를 사용합니다.

- 기록시각
- 속도
- RPM
- 브레이크 신호
- GPS(지원 차량)
- 방위각

CDT는 기사 배차시간과 차량변경 이벤트를 이용해 기사에게 연결합니다.

### 자체 후보 이벤트

- 급출발 후보
- 급가속 후보
- 급감속 후보
- 급정지 후보
- 회사 관리속도 초과 후보

이 값은 **eTAS 공식 판정값이 아닙니다.**

도로 제한속도, 제조사 G센서 판정, 영상 등 추가 정보가 없는 상태에서 기사 과실이나 교통법규 위반을 확정하지 않습니다.

---

# 9. BIS 차량변경 감시

창원시 자체 OpenAPI는 **2027년 1월 1일 종료 예정**이므로 수집기는 국토교통부 TAGO를 기본으로 사용합니다.

사용 API:

```text
국토교통부_(TAGO)_버스노선정보
국토교통부_(TAGO)_버스위치정보
```

수집기는 오늘 배차표의 노선별 예정차량과 실시간 위치차량을 비교합니다.

### 차량교체 판정 방식

1. 배차표 예정차량 목록 구성
2. TAGO 실시간 차량 목록 조회
3. 예정차량이 사라지고 새로운 차량이 나타나는지 확인
4. 이전 위치 정류소 순서와 새 차량 위치 비교
5. 동일 변화가 연속 polling에서 유지될 때 변경 후보 확정
6. **차량변경 이벤트만 Supabase에 저장**

실시간 전체 위치 스냅샷은 `collector_state.json`에만 임시 유지합니다.

> 공개 BIS 데이터만으로 운행순위를 100% 확정하기 어려운 경우가 있으므로, 시스템은 신뢰도(high/medium)를 함께 저장합니다. 필요 시 관리자가 회사 내부 BIS 자료와 대조해야 합니다.

---

# 10. 기사 화면

기사는 본인 이름으로 로그인합니다.

확인 가능 정보:

- 최근 eTAS 안전운전 수준
- 공단 위험운전 행동점수
- 종합 진단/권고문
- CDT 후보 이벤트 요약
- 본인 차량·노선 배차이력
- 운행 중 차량교체 이력
- 분석자료 확인여부

다른 기사의 자료는 조회할 수 없습니다.

---

# 11. 관리자 화면

- 배차표 업로드
- eTAS 리포트 업로드
- 오늘 CDT 수집상태
- BIS 차량변경
- 기사 계정 / 1111 초기화
- 기사 분석결과 확인여부
- 작업자/작업시간 감사로그

---

# 12. 검증된 샘플

첨부 배차표 구조:

- `20261016_배차.xls`: 255개 비어있지 않은 행, 차량·기사별 근무시각 구조 확인
- `20261016_배차2.xls`: 128개 비어있지 않은 행, 노선·운행순위·오전/오후 승무원 구조 확인

첨부 eTAS 리포트:

- 운전자 예시: 강명구B
- 분석기간: 2026년 07월
- 안전운전 수준: 양호
- 전월대비 행동별 점수와 권고문 구조 확인

CDT 파서는 이전 제공된 실제 DT-202 원본 2건으로 재시험했습니다.

- 경남71자1101: 46,345 레코드, 적산거리 219.676km
- 경남71자1108: 67,595 레코드, 적산거리 330.196km

이는 프로그램 파서의 구조검증 결과이며, 자체 급가감속 후보값이 교통안전공단 공식 판정과 동일하다는 의미는 아닙니다.

---

# 13. 운영 권장 순서

```text
1. Supabase SQL 설치
2. 관리자 비밀번호 변경
3. 배차표 2종 업로드
4. 기사 계정 확인
5. eTAS 리포트 샘플 업로드
6. 기사 모바일 로그인/확인 테스트
7. 회사 PC Collector 실행
8. CDT 자동수집 테스트
9. TAGO BIS 키 설정 후 차량변경 감시 테스트
10. 시범노선 → 전체노선 확대
```

## v1.0의 의도적인 제한

- 신호위반 자동 영상판정은 이번 프롬프트 핵심 범위가 아니므로 포함하지 않음
- 공개 BIS만으로 운행순위가 확정되지 않는 상황은 휴리스틱+관리자 검토 방식
- 공단 eTAS 점수와 자체 CDT 이벤트는 분리
- `1111`은 초기 비밀번호일 뿐이며 첫 로그인 후 재사용 금지

---

# 14. 운영 전 꼭 확인할 사항

- 기사 로그인 ID가 이름이므로 **동명이인이 있으면 동일 계정으로 구분할 수 없습니다.** 첨부 샘플처럼 `이태규B`, `김영상B` 등 회사의 기존 식별명 규칙을 유지하거나 별도 사번 기반 식별정책을 정해야 합니다.
- 초기 비밀번호 `1111`은 첫 로그인용이며 즉시 변경됩니다. 운영환경에서는 Netlify/Supabase HTTPS를 사용합니다.
- 브라우저에는 Supabase `service_role` key를 절대 넣지 않습니다.
- Collector의 TAGO 차량교체 판정은 공개 BIS의 위치변화에 근거한 후보판정입니다. 실제 운행순위/차량교체 확정은 초기 시범기간에 회사 BIS 기록과 대조해야 합니다.
- 상세 검증결과: `docs/VALIDATION_REPORT.md`
- 설치 체크리스트: `docs/INSTALL_CHECKLIST.md`

## 로그인에서 `function crypt(...) does not exist` 오류가 날 때

Supabase의 `pgcrypto` 확장 기능은 보통 `extensions` 스키마에 설치됩니다. 초기 v1.0.0 SQL의 로그인 함수는 `search_path=public`으로 고정되어 있어 프로젝트 환경에 따라 `crypt()`/`gen_salt()`를 찾지 못할 수 있습니다.

기존 DB를 삭제하거나 다시 만들 필요는 없습니다.

1. Supabase Dashboard → SQL Editor를 엽니다.
2. `sql/02_login_crypt_hotfix.sql` 내용을 전체 복사하여 실행합니다.
3. 결과의 `extension_schema`가 `extensions` 또는 `public`으로 표시되고, 관리자 계정이 조회되는지 확인합니다.
4. 웹앱을 새로고침하고 다시 로그인합니다.

v1.0.1의 `sql/01_schema.sql`에는 이 수정이 이미 반영되어 있습니다.
