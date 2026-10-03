@echo off
rem Backup wheel helper: turns your G29 with FSD when the mod cannot drive the wheel motor itself.
rem First time: pip install pysdl2 pysdl2-dll websocket-client
rem and turn OFF force feedback for the wheel in BeamNG (Options > Controls).
cd /d "%~dp0"
python wheel_helper.py %*
if errorlevel 1 pause
