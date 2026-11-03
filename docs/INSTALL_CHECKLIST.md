# 설치 체크리스트

## Supabase
- [ ] 새 프로젝트 생성
- [ ] SQL Editor에서 `sql/01_schema.sql` 전체 실행
- [ ] Project URL 확인
- [ ] Publishable/anon key 확인 (service_role 사용 금지)

## 웹앱
- [ ] `config.js`에 URL/key 입력 또는 첫 화면에서 저장
- [ ] 관리자 / 1111 최초 로그인
- [ ] 관리자 비밀번호 즉시 변경
- [ ] 배차표 2종 업로드
- [ ] 기사 계정 자동생성 확인
- [ ] eTAS 샘플 리포트 업로드
- [ ] 기사 계정으로 로그인하여 확인버튼 시험

## 회사 PC Collector
- [ ] Python 3.10 이상 설치
- [ ] `collector/setup_windows.bat` 실행
- [ ] Supabase URL/key와 변경한 관리자 비밀번호 입력
- [ ] `taco_folder`가 `E:\Choyoung\ADTviewer\Data`인지 확인
- [ ] 공공데이터포털에서 TAGO 버스노선정보/버스위치정보 활용신청 및 서비스키 입력
- [ ] `start_collector.bat` 수동 시험
- [ ] CDT 신규파일 생성 시 자동분석 확인
- [ ] BIS 실제 차량교체 사례와 탐지결과 대조
- [ ] 검증 후 `install_autostart_task.bat` 관리자 실행

## GitHub / Netlify
- [ ] GitHub Desktop에서 프로젝트 폴더 저장소 생성
- [ ] Commit / Push
- [ ] Netlify에서 GitHub 저장소 연결
- [ ] Build command 없음
- [ ] Publish directory `.`
- [ ] 운영 URL에서 로그인 및 모바일 화면 시험

## Windows Collector v1.0.2 확인
- [ ] BAT 파일이 `collector` 폴더에 모두 존재하는지 확인
- [ ] `setup_windows.bat` 실행 시 깨진 한글/명령 오류가 없는지 확인
- [ ] `start_collector.bat` 수동 실행 정상 확인
- [ ] 자동실행은 수동 시험 후 관리자 권한으로 등록
