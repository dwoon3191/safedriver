@echo off
chcp 65001 >nul
cd /d "%~dp0"
py -3 --version >nul 2>&1
if errorlevel 1 (
 echo Python 3 설치가 필요합니다. 설명서의 PC 준비 항목을 확인하세요.
 pause
 exit /b 1
)
py -3 -m venv .venv_monthly
if errorlevel 1 goto fail
.venv_monthly\Scripts\python.exe -m pip install -r requirements_monthly.txt
if errorlevel 1 goto fail
.venv_monthly\Scripts\python.exe -m playwright install chromium
if errorlevel 1 goto fail
echo 설치 완료. 공단수집기_실행.bat을 여세요.
pause
exit /b 0
:fail
echo 설치 실패. 위 오류를 확인한 뒤 다시 실행하세요.
pause
exit /b 1
