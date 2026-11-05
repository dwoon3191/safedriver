@echo off
setlocal
for %%D in ("%~dp0..") do set "BASE=%%~fD"
cd /d "%BASE%"
where py >nul 2>nul
if not errorlevel 1 (py -3 daewoon_collector.py & goto finish)
where python >nul 2>nul
if not errorlevel 1 (python daewoon_collector.py & goto finish)
echo ERROR: Python 3 was not found.
:finish
pause
endlocal
