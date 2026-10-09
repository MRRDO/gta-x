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

# winget id -> @(file pattern in ..\installers, silent arguments or 'MSI'). Anything not listed (or that fails) uses winget.
$offline = @{
  'Google.Chrome'          = @('ChromeStandaloneSetup64.exe', '/silent /install')
  'AnyDesk.AnyDesk'        = @('AnyDesk.exe', '--install "C:\Program Files (x86)\AnyDesk" --start-with-win --silent')
  'Git.Git'                = @('Git-*-64-bit.exe', '/VERYSILENT /NORESTART')
  'OpenJS.NodeJS.LTS'      = @('node-v*-x64.msi', 'MSI')
  'Python.Python.3.12'     = @('python-3.12.*-amd64.exe', '/quiet InstallAllUsers=1 PrependPath=1')
  'Cloudflare.cloudflared' = @('cloudflared-windows-amd64.msi', 'MSI')
  '7zip.7zip'              = @('7z*-x64.exe', '/S')
  'Tailscale.Tailscale'    = @('tailscale-setup-*-amd64.msi', 'MSI')
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue) -and -not (Test-Path $inst)) {
  Write-Host 'winget is not installed. Open the Microsoft Store, search "App Installer", install/update it, then run this again.' -ForegroundColor Yellow
  Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1'
  exit 1
}
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
if ($hasWinget) { winget source update | Out-Null }
$failed = @()
foreach ($g in $groups.Keys) {
  $go = $All
  if (-not $All) { $a = Read-Host "`nInstall group '$g'? [Y/n]"; $go = ($a -eq '' -or $a -match '^[Yy]') }
  if (-not $go) { continue }
  foreach ($p in $groups[$g]) {
    $id, $name = $p
    Write-Host "== $name" -ForegroundColor Cyan
    $off = $offline[$id]
    $local = if ($off -and (Test-Path $inst)) { Get-ChildItem $inst -File -Filter $off[0] | Sort-Object Name -Descending | Select-Object -First 1 } else { $null }
    if ($local) {
      Write-Host "   offline installer: $($local.Name)"
      if ($off[1] -eq 'MSI') { $p = Start-Process msiexec.exe -ArgumentList "/i `"$($local.FullName)`" /qn /norestart" -Wait -PassThru }
      else { $p = Start-Process $local.FullName -ArgumentList $off[1] -Wait -PassThru }
      if ($p.ExitCode -in 0, 3010) { continue }
      Write-Host "   offline installer exited with $($p.ExitCode), trying winget instead" -ForegroundColor Yellow
    }
    winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { $failed += "$name ($id)" }
  }
}
if ($failed) { Write-Host "`nThese did not install (wrong id, already installed, or no internet). Tell Claude the list:" -ForegroundColor Yellow; $failed | ForEach-Object { Write-Host "  $_" } } else { Write-Host "`nAll done." -ForegroundColor Green }
Write-Host 'After Ollama is installed: open a terminal and run  ollama pull llama3.2:1b'
