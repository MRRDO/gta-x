@echo off
setlocal
rem OptiPlex tools menu. Asks for administrator rights (some steps change Windows settings).
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
:menu
cd /d "%~dp0"
cls
echo ============================================
echo   OPTIPLEX TOOLS  (read README_FIRST.txt)
echo ============================================
echo  1  Collect facts + benchmark   (read-only, then offers to email you)
echo  2  Windows setup               (asks before each change)
echo  3  Install apps                (winget)
echo  4  Install Car Mode            (Tesla bridge + app)
echo  5  BeamNG settings from laptop (backs up first)
echo  6  Training on / off           (learns only when idle)
echo  7  Open this folder
echo  8  Benchmark plan: what is done / left
echo  9  Show + email the newest results and specs
echo  A  Voice assistant + sound outputs (speech, AI, EQ, output picker)
echo  Q  Quit
echo.
set /p c=Choose: 
if /i "%c%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Benchmark.ps1" & powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Email-Results.ps1" & pause & goto menu
if /i "%c%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Windows-Tune.ps1" & pause & goto menu
if /i "%c%"=="3" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-Apps.ps1" & pause & goto menu
if /i "%c%"=="4" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-CarMode.ps1" & pause & goto menu
if /i "%c%"=="5" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Apply-BeamNG-Settings.ps1" & pause & goto menu
if /i "%c%"=="6" goto training
if /i "%c%"=="7" start "" "%~dp0" & goto menu
if /i "%c%"=="8" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Benchmark.ps1" -Matrix & notepad "%~dp0BENCHMARK-PLAN.txt" & pause & goto menu
if /i "%c%"=="9" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Email-Results.ps1" & pause & goto menu
if /i "%c%"=="A" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Install-VoiceAudio.ps1" & pause & goto menu
if /i "%c%"=="Q" exit /b
goto menu
:training
echo.
echo  1  Switch training ON  (starts waiting for idle time)
echo  2  Switch training OFF
set /p t=Choose: 
if "%t%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Train-WhenIdle.ps1" -On & pause
if "%t%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Train-WhenIdle.ps1" -Off & pause
goto menu
