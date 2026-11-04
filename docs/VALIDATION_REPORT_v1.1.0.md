# SafeDrive AI v1.1.0 검증보고서

## 정적 검증

- `assets/app.js`: Node.js 구문검사 통과
- `collector/daewoon_collector.py`: Python 컴파일 검사 통과
- `collector/collector_control.pyw`: Python 컴파일 검사 통과
- BAT 파일: ASCII + CRLF 형식 확인
- ZIP 패키지: 생성 후 `unzip -t` 무결성 검사 통과

## 로직 검증

- 4자리 차량번호 → `경남71자####` 표준화 시험 통과
- 파일명 `20261104_배차.xls` → `2026-11-04` 일자 추출 시험 통과
- BIS 1:1 지속 불일치 2회 확인 후 차량변경 이벤트 생성 단위시험 통과
- eTAS 행 데이터에서 운전자명·분석월·행동점수 파싱 단위시험 통과
- Collector 상태파일과 제어센터 상태표시 구조 검토 완료
- 실제 DT-202 CDT 2개 전체 113,940건 파싱 회귀시험 통과
  - 경남71자1101: 46,345건 / 219.676km
  - 경남71자1108: 67,595건 / 330.196km

## 현장 인수시험 필요사항

- 실제 Supabase에서 `05_operational_monitor_upgrade.sql` 실행
- Windows + Microsoft Excel 환경의 eTAS 자동수집
- 실제 TAGO 노선/차량 위치 응답과 대운교통 배차표 비교
- Windows 예약작업 백그라운드 실행 및 재부팅 후 자동시작
- Netlify 배포 후 모바일/PC 브라우저 UI
