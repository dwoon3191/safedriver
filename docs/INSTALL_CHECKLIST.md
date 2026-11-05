# SafeDrive AI v1.3.0 설치 체크리스트

## 웹·DB
- [ ] 기존 `config.js` 별도 백업
- [ ] 기존 Supabase 데이터 백업 또는 스냅샷 확인
- [ ] 기존 v1.2.0이면 `sql/07_collector_usage_monthly_fix.sql` 실행
- [ ] 신규 설치이면 `sql/01_schema.sql` 실행
- [ ] `index.html`, `assets/`, `netlify.toml` 교체
- [ ] 기존 `config.js` 복원
- [ ] GitHub Push 및 Netlify Published 확인
- [ ] Ctrl+F5 후 관리자 로그인
- [ ] 관리자 최초 기기 URL/key 확인 완료
- [ ] 기사 계정에서 URL/key 입력 없이 로그인 확인

## Collector
- [ ] Python 3.10 이상 설치
- [ ] 기존 `collector_config.json` 백업
- [ ] 기존 `collector_state.json` 백업
- [ ] 새 Collector 폴더 배치
- [ ] 설정·상태파일 복원
- [ ] `SafeDrive_Collector_Control.bat` 실행
- [ ] 환경설정 저장
- [ ] 전체 연결진단 통과
- [ ] Windows 자동실행 설치
- [ ] 수집 시작
- [ ] 제어센터 종료 후 백그라운드 수집 유지 확인
- [ ] Windows 재로그인 후 자동 시작 확인

## 현장검증
- [ ] 일일 배차표 다중 업로드
- [ ] 적용 시간표 버전·요일구분 확인
- [ ] 수집현황에서 노선별 예정/BIS 차량 확인
- [ ] 출발 전 대체차량 1건 검증
- [ ] 운행 중 교체차량 1건 검증
- [ ] 늦게 수집된 CDT의 과거 운행일 재매칭 검증
- [ ] 데이터 연계 화면에서 기사 분석 생성 확인
- [ ] 2026-10-01 이후 월별 분석 확인
- [ ] 기사 결과 확인 처리 및 관리자 확인현황 점검
- [ ] 기사 로그인 횟수·사용시간 누적 확인
