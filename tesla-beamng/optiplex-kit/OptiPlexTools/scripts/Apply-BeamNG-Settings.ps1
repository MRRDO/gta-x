<#
 Copies the laptop's BeamNG settings (put in ..\beamng-settings\ by the laptop session, with the frame rate cap
 already set to 60) into this PC's BeamNG user folder. The current settings are backed up first, into
 reports\beamng-settings-backup-<time>\. Close BeamNG before running this.
 If the game then runs badly, run menu 1 and tell Claude the numbers; lower settings are a copy-paste away.
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$src = Join-Path $root 'beamng-settings'
if (-not (Test-Path $src)) { Write-Host "No beamng-settings folder yet ($src). The laptop session creates it." -ForegroundColor Yellow; exit 1 }
if (Get-Process BeamNG.drive.x64 -ErrorAction SilentlyContinue) { Write-Host 'Close BeamNG first.' -ForegroundColor Yellow; exit 1 }
$userRoot = Join-Path $env:LOCALAPPDATA 'BeamNG\BeamNG.drive'
if (-not (Test-Path $userRoot)) { $userRoot = Join-Path $env:LOCALAPPDATA 'BeamNG.drive' }
if (-not (Test-Path $userRoot)) { Write-Host 'BeamNG user folder not found. Start the game once so it creates it.' -ForegroundColor Yellow; exit 1 }
$ver = Get-ChildItem $userRoot -Directory | Where-Object { $_.Name -match '^\d' } | Sort-Object Name -Descending | Select-Object -First 1
$dst = if ($ver) { Join-Path $ver.FullName 'settings' } else { Join-Path $userRoot 'current\settings' }
Write-Host "BeamNG settings folder: $dst"
$backup = Join-Path $root ("reports\beamng-settings-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
if (Test-Path $dst) { New-Item -ItemType Directory -Force -Path $backup | Out-Null; robocopy $dst $backup /E /NFL /NDL /NJH /NJS | Out-Null; Write-Host "Backed up to $backup" }
$a = Read-Host 'Copy the laptop settings over them? [y/N]'
if ($a -notmatch '^[Yy]') { Write-Host 'Nothing changed.'; exit 0 }
New-Item -ItemType Directory -Force -Path $dst | Out-Null
robocopy $src $dst /E /NFL /NDL /NJH /NJS | Out-Null
Write-Host 'Done. To undo: copy the backup folder back over the settings folder.' -ForegroundColor Green
