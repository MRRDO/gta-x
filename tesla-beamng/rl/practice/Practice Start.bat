@echo off
title Tesla FSD practice (close this window or run Practice Stop to end)
cd /d "%~dp0"
start "" http://127.0.0.1:8780
node practice.mjs
pause
