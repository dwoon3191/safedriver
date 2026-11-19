@echo off
setlocal
cd /d "%~dp0"
if errorlevel 1 goto fail
if not exist ".venv_monthly\Scripts\python.exe" goto missing
".venv_monthly\Scripts\python.exe" monthly_control.pyw
if errorlevel 1 goto fail
exit /b 0
:missing
echo Run the collector installation BAT file first.
pause
exit /b 1
:fail
echo Collector failed. Please capture this window for support.
pause
exit /b 1
