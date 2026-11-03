@echo off
setlocal
set "TASK_NAME=DaewoonSafeDriveCollector"

echo Removing scheduled task: %TASK_NAME%
schtasks /Delete /TN "%TASK_NAME%" /F
if errorlevel 1 goto not_removed

echo Task removed successfully.
goto finish

:not_removed
echo Task was not found or could not be removed.

:finish
echo.
pause
endlocal
