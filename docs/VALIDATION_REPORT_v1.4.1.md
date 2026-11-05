# SafeDrive AI v1.4.1 검증보고서

## 실제 첨부자료 검증

### 일일 노선·운행순위 CSV
- 파일: `20261104_report(1).csv`
- 인코딩: CP949/EUC-KR
- 데이터행: 127행
- 헤더: `일자,회사명,노선번호,운행순번,오전출발시간,오후출발시간,차량번호`
- v1.4.1 수정: `운행순번` 헤더 정식 인식
- AM/PM 확장 결과: 254건

### 기사 근무배차
- 파일: `20261104_배차.xls`
- 데이터: 254건
- 기사·차량·AM/PM 기준 일일 노선자료 매칭: **254/254건**

### 노선별 운행시간표
- 파일: `1.시내버스 노선별 운행시간표(2026. 9. 29.기준) ★ (1).xlsx`
- 시트: 9개
- 샘플 일일배차 노선 106, 107, 111 등이 시간표 내 존재함을 확인

## 코드검증
- `assets/app.js`: Node.js syntax check 통과
- `collector/daewoon_collector.py`: Python compile 통과
- `collector/collector_control.pyw`: Python compile 통과
- BIS 실제차량 binding이 예정차량 직접매칭보다 우선되는 단위시험 통과
- 일일배차 `planned_departure`가 BIS 활성회차 판정에 우선 적용되는 단위시험 통과
- CDT 하위폴더 재귀검색 로직 적용 확인
- Collector State 처리완료 + Supabase 미등록 시 자동 재처리 로직 적용 확인

## 데이터 보존
- `config.js` 미포함
- `collector_config.json` 미포함
- `collector_state.json` 미포함
- 기존 Supabase 데이터 삭제문 없음
- 업데이트 SQL은 테이블 보완/함수 교체/기존 배차 연결정보 보완 중심

## 현장 최종시험 필요
- 운영 TAGO 인증키로 실제 창원 노선 차량위치 수신
- 실제 배차와 다른 차량 1건 이상 탐지
- 실제 CDT 폴더/하위폴더 재귀검색 건수 확인
- 2026-10월 누적 CDT의 기사별 재매칭·월간 분석 생성 확인
