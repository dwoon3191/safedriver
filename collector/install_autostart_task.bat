@echo off
setlocal
cd /d "%~dp0"

set "TASK_NAME=DaewoonSafeDriveCollector"
set "DW_SCRIPT=%~dp0daewoon_collector.py"

echo ========================================
echo Daewoon SafeDrive Auto Start Installer
echo ========================================
echo.

net session >nul 2>nul
if errorlevel 1 goto need_admin

if not exist "%DW_SCRIPT%" goto missing_script
if not exist "collector_config.json" goto missing_config

where py >nul 2>nul
if not errorlevel 1 goto use_py
where python >nul 2>nul
if not errorlevel 1 goto use_python
goto missing_python

:use_py
for /f "usebackq delims=" %%P in (`py -3 -c "import sys; print(sys.executable)"`) do set "DW_PYEXE=%%P"
goto have_python

:use_python
for /f "usebackq delims=" %%P in (`python -c "import sys; print(sys.executable)"`) do set "DW_PYEXE=%%P"
goto have_python

:have_python
if not defined DW_PYEXE goto missing_python
set "DW_TASK_NAME=%TASK_NAME%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $a=New-ScheduledTaskAction -Execute $env:DW_PYEXE -Argument ('\"'+$env:DW_SCRIPT+'\"'); $t=New-ScheduledTaskTrigger -AtLogOn; Register-ScheduledTask -TaskName $env:DW_TASK_NAME -Action $a -Trigger $t -RunLevel Highest -Force | Out-Null"
if errorlevel 1 goto task_error

echo.
echo Auto-start task installed successfully.
echo Task name: %TASK_NAME%
echo It will run when this Windows user logs on.
goto finish

:need_admin
echo ERROR: Administrator permission is required.
echo Right-click this file and choose Run as administrator.
goto finish

:missing_script
echo ERROR: daewoon_collector.py was not found.
goto finish

:missing_config
echo ERROR: collector_config.json was not found.
echo Run setup_windows.bat first.
goto finish

:missing_python
echo ERROR: Python 3 was not found.
echo Install Python 3.10 or later and enable Add Python to PATH.
goto finish

:task_error
echo ERROR: Failed to create the scheduled task.
echo Check Windows Task Scheduler permissions.

:finish
echo.
pause
endlocal
