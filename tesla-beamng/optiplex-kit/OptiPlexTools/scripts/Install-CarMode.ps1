<#
 Puts the Tesla bridge on this PC in C:\car-mode and runs its own setup (tesla-beamng\setup.ps1: Node, Python,
 npm install, the BeamNG mod, the iPad app build, firewall, desktop shortcut).
 Source, in order: ..\car-mode\ on this folder (the laptop session puts it there), otherwise it tells you how to
 get it. It never asks for or types a GitHub password.
 The iPad link: start.bat starts the bridge with --tunnel, which uses Cloudflare (cloudflared) so the iPad gets an
 https address, and https is what lets the iPad use its camera and microphone.
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path (Split-Path -Parent $here) 'car-mode'
$dst = 'C:\car-mode'
if (Test-Path (Join-Path $src 'tesla-beamng\setup.ps1')) {
  Write-Host "Copying $src to $dst ..."
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  robocopy $src $dst /E /XD node_modules .git /NFL /NDL /NJH /NJS | Out-Null
} elseif (-not (Test-Path (Join-Path $dst 'tesla-beamng\setup.ps1'))) {
  Write-Host @"
No car-mode folder found next to these tools, and nothing in $dst yet.
Ways to get it:
  1. On the laptop: run the car-mode packager (laptop session does this) so ..\car-mode appears in this folder.
  2. Or install Git (menu 3), then in a terminal:  git clone <the gta-x repo> C:\car-mode  (you sign in to GitHub yourself)
     and check out the branch  claude/review-feedback-gyfm2f.
"@ -ForegroundColor Yellow
  exit 1
}
$setup = Join-Path $dst 'tesla-beamng\setup.ps1'
Write-Host "Running $setup ..." -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $setup
Write-Host "`nNext: start BeamNG, then double-click 'Tesla Bridge' on the desktop (or reboot if you set the Car Mode task)." -ForegroundColor Cyan
Write-Host 'The relay prints a QR code and an https link: open it on the iPad, add it to the Home Screen.'
