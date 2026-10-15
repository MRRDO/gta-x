@echo off
rem Windows Setup runs this once, as SYSTEM, at the very end of the install (before the first sign-in).
rem It makes the tools folder open by itself the first time you sign in.
if exist "C:\OptiPlexTools\START-HERE.cmd" (
  reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v OptiPlexTools /t REG_SZ /d "explorer.exe C:\OptiPlexTools" /f
)
exit /b 0
