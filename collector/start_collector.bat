@echo off
setlocal
cd /d "%~dp0"
echo ========================================
echo Daewoon SafeDrive Collector Diagnostic
echo ========================================
echo This console mode is for testing only.
echo Normal operation: install_autostart_task.bat + collector_control.bat
echo.
where py >nul 2>nul
if not errorlevel 1 goto found_py
where python >nul 2>nul
if not errorlevel 1 goto found_python
echo ERROR: Python 3 was not found.
goto finish
:found_py
set "PY_CMD=py -3"
goto python_ready
:found_python
set "PY_CMD=python"
:python_ready
if not exist "daewoon_collector.py" goto missing_collector
if not exist "collector_config.json" goto missing_config
%PY_CMD% "daewoon_collector.py"
goto finish
:missing_collector
echo ERROR: daewoon_collector.py was not found.
goto finish
:missing_config
echo ERROR: collector_config.json was not found.
echo Run setup_windows.bat first.
:finish
echo.
pause
endlocal
