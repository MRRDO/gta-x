@echo off
if not exist "%USERPROFILE%\.tesla-beamng\soak" mkdir "%USERPROFILE%\.tesla-beamng\soak"
echo stop> "%USERPROFILE%\.tesla-beamng\soak\STOP"
echo Asked the soak test to stop after the current step. It writes and uploads the report, then exits.
timeout /t 3 >nul
