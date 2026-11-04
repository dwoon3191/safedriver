# SafeDrive AI v1.2.0 설치 체크리스트

## A. Supabase
- [ ] 기존 DB 백업
- [ ] v1.1.0 사용 중이면 `06_delayed_taco_minimal_storage.sql` 실행
- [ ] v1.0.4 이하이면 `05` 실행 후 `06` 실행
- [ ] 신규 프로젝트는 `01_schema.sql`만 실행
- [ ] 관리자/1111 로그인 후 비밀번호 변경

## B. 웹앱
- [ ] 기존 `config.js` 별도 보존
- [ ] 새 `index.html`, `assets/`, `netlify.toml` 반영
- [ ] 기존 `config.js`를 웹 루트에 유지
- [ ] GitHub Commit/Push
- [ ] Netlify Published 확인
- [ ] Ctrl+F5
- [ ] 기사 휴대전화에서 URL/key 없이 로그인 확인

## C. 기준정보
- [ ] 기사 근무/배차 파일 업로드
- [ ] 일일 노선·운행순위 파일 함께 업로드
- [ ] 적용일 배차 조회
- [ ] 노선 운행시간표 업로드
- [ ] 적용시작·종료일 확인
- [ ] 방학 시간표 구분 등록
- [ ] 평일 공휴일은 특수 운행일로 등록

## D. Collector
- [ ] Python 3.10 이상
- [ ] 기존 `collector_config.json` 백업/유지
- [ ] 기존 `collector_state.json` 백업/유지
- [ ] 새 Collector 코드 교체
- [ ] TAGO 버스노선정보·버스위치정보 권한 확인
- [ ] `setup_windows.bat` 실행
- [ ] `install_autostart_task.bat` 관리자 실행
- [ ] `collector_control.bat`에서 ONLINE 확인
- [ ] CMD/제어창 종료 후 백그라운드 유지 확인

## E. 현장검증
- [ ] TAGO 창원시 코드 조회 성공
- [ ] 노선별 실제차량 조회 성공
- [ ] 출발 전 대체차량 검증
- [ ] 중간 차량교체 검증
- [ ] 새 CDT 자동수집 검증
- [ ] 과거 운행일 CDT 지연수집 검증
- [ ] Supabase에 원본 CDT/BIS가 없는지 확인
- [ ] 기사별 리포트와 확인버튼 검증
