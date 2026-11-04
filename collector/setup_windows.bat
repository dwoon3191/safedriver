@echo off
setlocal
cd /d "%~dp0"

echo ========================================
echo Daewoon SafeDrive Collector Setup
echo ========================================
echo.

where py >nul 2>nul
if not errorlevel 1 goto found_py
where python >nul 2>nul
if not errorlevel 1 goto found_python

echo ERROR: Python 3 was not found.
echo Install Python 3.10 or later and enable Add Python to PATH.
goto finish

:found_py
set "PY_CMD=py -3"
goto python_ready
:found_python
set "PY_CMD=python"
:python_ready
%PY_CMD% --version
if errorlevel 1 goto python_error

if exist "collector_config.json" goto config_exists
copy /Y "collector_config.example.json" "collector_config.json" >nul
if errorlevel 1 goto config_error

:config_exists
echo.
echo Opening collector_config.json in Notepad.
echo Required: Supabase URL/key, web admin password, TAGO key.
echo Existing collector_config.json and collector_state.json are preserved.
start "" notepad.exe "collector_config.json"
echo.
echo 1. Save collector_config.json.
echo 2. Run install_autostart_task.bat as administrator.
echo 3. Open collector_control.bat to view status and start/stop.
goto finish

:python_error
echo ERROR: Python was found but could not run.
goto finish
:config_error
echo ERROR: collector_config.json could not be created.
:finish
echo.
pause
endlocal
