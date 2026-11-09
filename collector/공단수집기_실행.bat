@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist .venv_monthly\Scripts\python.exe (
 echo 공단수집기_설치.bat을 먼저 실행하세요.
 pause
 exit /b 1
)
.venv_monthly\Scripts\python.exe monthly_control.pyw
if errorlevel 1 pause
