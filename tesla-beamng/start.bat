@echo off
rem Tesla UI <-> BeamNG bridge: starts the relay and the wheel-buttons companion, opens the test page.
rem Start BeamNG first (or after, the relay waits for it). Close the windows to stop.
cd /d "%~dp0"

rem --tunnel: an https address through Cloudflare (for the live app + iPad mic/camera); falls back to Wi-Fi if cloudflared is missing
start "Tesla relay" cmd /k npm run bridge -- --tunnel

rem the wheel companion (reads wheel buttons for Settings > Wheel buttons); needs Python + pysdl2
set PY=
where py >nul 2>nul && set PY=py
if not defined PY where python >nul 2>nul && set PY=python
if defined PY (
  %PY% -c "import sdl2, websocket" >nul 2>nul && start "Wheel buttons" /min cmd /k %PY% bridge\wheel_helper.py --buttons
)

rem give the relay a moment, then open the test page (scan the QR code in the relay window with the iPad: new code every start)
timeout /t 4 /nobreak >nul
start "" http://localhost:8765/
