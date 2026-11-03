@echo off
chcp 65001 > nul
cd /d "%~dp0"
set SCRIPT=%~dp0start_collector.bat
schtasks /Create /TN "DaewoonSafeDriveCollector" /TR "\"%SCRIPT%\"" /SC ONLOGON /RL HIGHEST /F
if errorlevel 1 (
 echo 작업 스케줄러 등록에 실패했습니다. 관리자 권한으로 다시 실행하세요.
) else (
 echo Windows 로그인 시 자동 시작 작업을 등록했습니다.
)
pause
