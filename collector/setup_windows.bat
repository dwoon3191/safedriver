@echo off
chcp 65001 > nul
cd /d "%~dp0"
where python >nul 2>nul
if errorlevel 1 (
  echo [오류] Python 3가 설치되어 있지 않습니다.
  echo https://www.python.org 에서 Python 3.10 이상을 설치하고 Add Python to PATH를 체크하세요.
  pause
  exit /b 1
)
if not exist collector_config.json copy collector_config.example.json collector_config.json >nul
notepad collector_config.json
echo.
echo 설정 저장 후 start_collector.bat를 실행하세요.
pause
