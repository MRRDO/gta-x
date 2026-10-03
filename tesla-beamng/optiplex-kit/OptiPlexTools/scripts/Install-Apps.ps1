<#
 Installs the apps Quentin asked for (Chrome, AnyDesk, Claude, ...) with winget, one at a time.
 If a package id is wrong or already installed it says so and carries on.
   Install-Apps.ps1            asks before each group
   Install-Apps.ps1 -All       installs everything without asking
 Offline installers, if the laptop session downloaded any, are in ..\installers\ and are tried first.
#>
param([switch]$All)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$inst = Join-Path (Split-Path -Parent $here) 'installers'

$groups = [ordered]@{
  'Everyday (what you asked for)' = @(
    @('Google.Chrome', 'Chrome'), @('AnyDesk.AnyDesk', 'AnyDesk'), @('Anthropic.Claude', 'Claude'), @('7zip.7zip', '7-Zip'), @('VideoLAN.VLC', 'VLC'), @('Notepad++.Notepad++', 'Notepad++'))
  'Car Mode needs these' = @(
    @('Git.Git', 'Git'), @('OpenJS.NodeJS.LTS', 'Node.js LTS'), @('Python.Python.3.12', 'Python 3.12'), @('Cloudflare.cloudflared', 'Cloudflare tunnel (iPad camera over https)'), @('Tailscale.Tailscale', 'Tailscale (remote access)'))
  'Monitoring and the wheel' = @(
    @('REALiX.HWiNFO', 'HWiNFO (temps, clocks)'), @('Guru3D.Afterburner', 'MSI Afterburner (FPS overlay)'), @('Logitech.GHUB', 'Logitech G HUB (G29)'))
  'Game and AI' = @(
    @('Valve.Steam', 'Steam (BeamNG)'), @('Ollama.Ollama', 'Ollama (FSD Assistant, small local AI)'), @('LizardByte.Sunshine', 'Sunshine (stream the game to the iPad, optional)'))
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Write-Host 'winget is not installed. Open the Microsoft Store, search "App Installer", install/update it, then run this again.' -ForegroundColor Yellow
  Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1'
  exit 1
}
winget source update | Out-Null
$failed = @()
foreach ($g in $groups.Keys) {
  $go = $All
  if (-not $All) { $a = Read-Host "`nInstall group '$g'? [Y/n]"; $go = ($a -eq '' -or $a -match '^[Yy]') }
  if (-not $go) { continue }
  foreach ($p in $groups[$g]) {
    $id, $name = $p
    Write-Host "== $name" -ForegroundColor Cyan
    $local = if (Test-Path $inst) { Get-ChildItem $inst -File | Where-Object { $_.BaseName -like "*$($id.Split('.')[-1])*" } | Select-Object -First 1 } else { $null }
    if ($local) { Write-Host "   offline installer: $($local.Name) (run it by hand if silent mode does not work)"; Start-Process $local.FullName -ArgumentList '/S' -Wait; continue }
    winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { $failed += "$name ($id)" }
  }
}
if ($failed) { Write-Host "`nThese did not install (wrong id, already installed, or no internet). Tell Claude the list:" -ForegroundColor Yellow; $failed | ForEach-Object { Write-Host "  $_" } } else { Write-Host "`nAll done." -ForegroundColor Green }
Write-Host 'After Ollama is installed: open a terminal and run  ollama pull llama3.2:1b'
