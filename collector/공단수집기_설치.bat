@echo off
setlocal
cd /d "%~dp0"
if errorlevel 1 goto fail
py -3 --version
if errorlevel 1 goto missing
py -3 -m venv .venv_monthly
if errorlevel 1 goto fail
".venv_monthly\Scripts\python.exe" -m pip install -r requirements_monthly.txt
if errorlevel 1 goto fail
".venv_monthly\Scripts\python.exe" -m playwright install chromium
if errorlevel 1 goto fail
echo Installation completed. You can now run the collector launcher.
pause
exit /b 0
:missing
echo Python launcher not found. Install Python 3 with the py launcher.
:fail
echo Installation failed. Please capture this window for support.
pause
exit /b 1
