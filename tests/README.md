# 개발자 검증
운영 DB에 테스트 코드를 실행하지 마세요. 아래 DB 테스트는 로컬 인메모리 PGlite만 사용합니다.

- Python: `python tests/test_monthly_core.py` (openpyxl 등 requirements_monthly.txt 필요)
- Node gateway mock: `node tests/test_monthly_gateway.cjs`
- tests 폴더에서 `npm install` 후 `node test_monthly_db.mjs`. 기존 설치와 합쳐진 폴더의 sql/01_schema.sql을 테스트 기준으로 사용합니다. 별도 기준 파일은 BASELINE_SQL 환경변수로 절대경로 지정.
- UI: tests 폴더에서 `npx playwright install chromium` 후 `node test_ui.mjs`, `node test_full-ui.mjs`. 기존 app.css가 필요합니다. API는 mock이며 실제 서버에 연결하지 않습니다.
- pgcrypto 해시는 테스트용 대체 함수이며 실제 암호화 동작을 검증하지 않습니다.
