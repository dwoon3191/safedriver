# 대운교통 SafeDrive AI v1.1.0 설치 체크리스트

## A. Supabase

- [ ] 기존 v1.0.4 운영 DB이면 `sql/05_operational_monitor_upgrade.sql` 1회 실행
- [ ] `04_dispatch_import_timeout_fix.sql` 미실행 시 먼저 실행
- [ ] 신규 DB이면 `sql/01_schema.sql` 전체 실행
- [ ] 웹앱에서 관리자 로그인이 정상인지 확인

## B. GitHub / Netlify

- [ ] `index.html`, `assets/`, `netlify.toml` 반영
- [ ] GitHub Push 완료
- [ ] Netlify Published 확인
- [ ] 브라우저 `Ctrl + F5`
- [ ] 최초 화면에서 Supabase URL과 publishable/anon key 저장

## C. 배차표

- [ ] `20261104_배차.xls` 등 일자별 파일 여러 개 동시 선택
- [ ] 파일별 인식건수와 운행일자 확인
- [ ] Supabase 저장 후 실제 운행일자로 조회

## D. Collector

- [ ] Python 3.10 이상 설치 및 PATH 확인
- [ ] `collector/setup_windows.bat` 실행
- [ ] Supabase URL/key, 관리자 ID/비밀번호 입력
- [ ] `taco_folder` 확인
- [ ] `etas_folder` 생성·확인
- [ ] TAGO 일반 인증키 입력
- [ ] `install_autostart_task.bat` 관리자 권한 실행
- [ ] `collector_control.bat`에서 실행 상태 확인
- [ ] 제어센터 종료 후에도 백그라운드 수집 유지 확인

## E. 자동수집 현장시험

- [ ] 신규 CDT 생성 후 `수집현황`에서 자동 등록 확인
- [ ] eTAS Excel을 감시폴더에 저장한 뒤 자동 등록 확인
- [ ] BIS 마지막 조회시각과 조회노선 수 확인
- [ ] 실제 차량교체 사례에서 변경 이벤트 확인
- [ ] 기사별 리포트와 기사 확인 여부 확인

## F. 보안

- [ ] `collector_config.json`을 GitHub에 올리지 않음
- [ ] 실제 배차표·eTAS 리포트를 공개 저장소에 올리지 않음
- [ ] service_role key를 브라우저나 Collector에 사용하지 않음
