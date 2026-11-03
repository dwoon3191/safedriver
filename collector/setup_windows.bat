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
echo Then run this file again.
goto finish

:found_py
set "PY_CMD=py -3"
goto python_ready

:found_python
set "PY_CMD=python"
goto python_ready

:python_ready
echo Python found.
%PY_CMD% --version
if errorlevel 1 goto python_error

if exist "collector_config.json" goto config_exists

echo Creating collector_config.json ...
%PY_CMD% "daewoon_collector.py"
if errorlevel 1 goto config_error

:config_exists
if not exist "collector_config.json" goto config_error

echo.
echo Opening collector_config.json in Notepad.
echo Enter Supabase URL, anon/publishable key, admin password, and TAGO key.
start "" notepad.exe "collector_config.json"
echo.
echo After saving the config, run start_collector.bat.
goto finish

:python_error
echo ERROR: Python was found but could not run.
goto finish

:config_error
echo ERROR: collector_config.json could not be created.
echo Check that daewoon_collector.py exists in this folder.

:finish
echo.
pause
endlocal
