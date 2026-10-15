@echo off
title Tesla FSD practice - runs until stopped (Practice Stop to end)
cd /d "%~dp0"
start "" http://127.0.0.1:8780
:loop
node practice.mjs
if exist "%USERPROFILE%\.tesla-beamng\practice\STOP" goto :eof
timeout /t 10 >nul
goto loop
