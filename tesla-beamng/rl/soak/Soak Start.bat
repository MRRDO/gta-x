@echo off
title Tesla FSD soak test - runs until stopped (Soak Stop.bat)
cd /d "%~dp0\..\.."
echo Starting the FSD soak test. Let it run; it stops by itself after SOAK_HOURS (default 6) or when you run "Soak Stop.bat".
node rl\soak\soak.mjs
echo Soak test finished. Report: %USERPROFILE%\.tesla-beamng\soak\
pause
