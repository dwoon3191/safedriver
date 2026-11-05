@echo off
setlocal
set "TASK_NAME=DaewoonSafeDriveCollector"
schtasks /End /TN "%TASK_NAME%" >nul 2>nul
schtasks /Delete /TN "%TASK_NAME%" /F
if errorlevel 1 echo Task was not found or could not be removed.
if not errorlevel 1 echo Task removed successfully.
pause
endlocal
