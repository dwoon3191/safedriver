@echo off
setlocal
for %%D in ("%~dp0..") do set "BASE=%%~fD"
cd /d "%BASE%"
set "TASK_NAME=DaewoonSafeDriveCollector"
set "DW_SCRIPT=%BASE%\daewoon_collector.py"
net session >nul 2>nul
if errorlevel 1 goto need_admin
if not exist "%DW_SCRIPT%" goto missing_script
if not exist "%BASE%\collector_config.json" goto missing_config
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
:have_python
for %%P in ("%DW_PYEXE%") do set "DW_PYDIR=%%~dpP"
set "DW_PYW=%DW_PYDIR%pythonw.exe"
if not exist "%DW_PYW%" set "DW_PYW=%DW_PYEXE%"
set "DW_TASK_NAME=%TASK_NAME%"
set "DW_BASE=%BASE%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $a=New-ScheduledTaskAction -Execute $env:DW_PYW -Argument ('\"'+$env:DW_SCRIPT+'\" --service') -WorkingDirectory $env:DW_BASE; $t=New-ScheduledTaskTrigger -AtLogOn; $s=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero); Register-ScheduledTask -TaskName $env:DW_TASK_NAME -Action $a -Trigger $t -Settings $s -RunLevel Highest -Force | Out-Null; Start-ScheduledTask -TaskName $env:DW_TASK_NAME"
if errorlevel 1 goto task_error
echo Background collector installed and started.
echo Task name: %TASK_NAME%
goto finish
:need_admin
echo ERROR: Administrator permission is required.
goto finish
:missing_script
echo ERROR: daewoon_collector.py was not found.
goto finish
:missing_config
echo ERROR: Save settings in SafeDrive Collector Control Center first.
goto finish
:missing_python
echo ERROR: Python 3 was not found.
goto finish
:task_error
echo ERROR: Failed to create or start the scheduled task.
:finish
pause
endlocal
