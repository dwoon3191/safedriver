# SafeDrive AI v1.4.1 기존환경 보존 갱신 체크리스트

## 갱신 전 백업
- [ ] 웹 루트의 `config.js` 백업
- [ ] `collector/collector_config.json` 백업
- [ ] `collector/collector_state.json` 백업
- [ ] 현재 GitHub Commit/Netlify Published 상태 확인

## Supabase
- [ ] 기존 테이블/데이터 삭제 금지
- [ ] SQL Editor에서 `sql/08_v1_4_1_safe_update.sql` 1회 실행
- [ ] 기사·배차·시간표·BIS·CDT 기존 행 유지 확인

## 웹 프로그램
- [ ] `index.html`, `assets/`, `netlify.toml`만 교체
- [ ] 기존 `config.js` 복원/유지
- [ ] GitHub Desktop Commit → Push
- [ ] Netlify Published 확인
- [ ] 브라우저 Ctrl+F5

## Collector
- [ ] 신규 collector 코드 배치
- [ ] 기존 `collector_config.json` 복원
- [ ] 기존 `collector_state.json` 복원
- [ ] `SafeDrive_Collector_Control.bat` 실행
- [ ] 자동실행 작업을 현재 v1.4.1 경로로 재설치
- [ ] 수집 시작 후 `DaewoonCollector-1.4.1` 표시 확인

## 현장 시험
- [ ] `20261104_report.csv` 업로드 시 127행 → AM/PM 254건 인식
- [ ] 기사 근무배차 254건과 노선·순번 254건 자동 병합
- [ ] 일일배차 목록에서 노선/순번이 `-`가 아닌 값으로 표시
- [ ] 시간표는 새 버전 등록 전까지 계속 적용
- [ ] Collector 수집현황에 폴더 내 CDT 개수가 표시
- [ ] 하위폴더 CDT도 검색되는지 확인
- [ ] BIS 활성노선/예정차량/실제차량 수가 표시
- [ ] 배차와 다른 실제차량이 `실제 운행차량` 이력에 표시
- [ ] 실제차량 CDT가 해당 기사 분석에 연결
