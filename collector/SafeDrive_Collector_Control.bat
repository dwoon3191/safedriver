@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if not errorlevel 1 goto use_py
where pythonw >nul 2>nul
if not errorlevel 1 goto use_pythonw
where python >nul 2>nul
if not errorlevel 1 goto use_python
echo ERROR: Python 3 was not found.
echo Install Python 3.10 or later and enable Add Python to PATH.
pause
goto finish
:use_py
for /f "usebackq delims=" %%P in (`py -3 -c "import sys; print(sys.executable)"`) do set "PYEXE=%%P"
for %%P in ("%PYEXE%") do set "PYW=%%~dpPpythonw.exe"
if not exist "%PYW%" set "PYW=%PYEXE%"
start "" "%PYW%" "%~dp0collector_control.pyw"
goto finish
:use_pythonw
start "" pythonw "%~dp0collector_control.pyw"
goto finish
:use_python
start "" python "%~dp0collector_control.pyw"
:finish
endlocal
