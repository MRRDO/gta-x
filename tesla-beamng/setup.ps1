<#
  Tesla UI <-> BeamNG bridge: one-time setup on Windows (re-run any time to update).

  Right-click > "Run with PowerShell", or from a terminal in this folder:
      powershell -ExecutionPolicy Bypass -File .\setup.ps1
  Options:
      -BeamNGUserFolder "D:\BeamNG"   if BeamNG's user folder isn't the default
      -SkipPython                      don't set up the wheel companion (wheel buttons / backup FFB)
      -NoShortcut                      don't put "Tesla Bridge" on the desktop

  What it does (each step says OK / what to do):
    1. Node.js LTS, Python 3.12 (wheel companion) and cloudflared (https tunnel for the iPad app) via winget if missing
    2. npm install
    3. builds the mod and copies tesla_bridge.zip into BeamNG's mods folder
    4. pip installs the wheel companion's packages
    5. allows the relay through Windows Firewall on private networks (asks for admin)
    6. desktop shortcut "Tesla Bridge" -> start.bat
    7. runs the setup check (npm run doctor)
#>
[CmdletBinding()]
param(
  [string]$BeamNGUserFolder = '',
  [switch]$SkipPython,
  [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "   OK  $text" -ForegroundColor Green }
function Warn($text) { Write-Host "   !!  $text" -ForegroundColor Yellow }
function Has($cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Refresh-Path {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$machine;$user"
}

function Winget-Install($id, $name) {
  if (-not (Has 'winget')) {
    Warn "winget not found: install $name by hand, then run setup again"
    return $false
  }
  Write-Host "   installing $name (winget) ..."
  winget install --id $id -e --accept-package-agreements --accept-source-agreements --silent | Out-Host
  Refresh-Path
  return $true
}

# ---------------------------------------------------------------- 1. Node / Python
Step 'Node.js'
if (-not (Has 'node')) { Winget-Install 'OpenJS.NodeJS.LTS' 'Node.js LTS' | Out-Null }
if (-not (Has 'node')) { throw 'Node.js is not installed (https://nodejs.org). Install it and run setup again.' }
$nodeMajor = [int]((node -v).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 20) { throw "Node $(node -v) is too old; install Node 20 or newer (winget install OpenJS.NodeJS.LTS)." }
Ok "Node $(node -v)"

$py = $null
if (-not $SkipPython) {
  Step 'Python (wheel companion)'
  foreach ($c in @('py', 'python')) {
    if (Has $c) {
      & $c --version *> $null
      if ($LASTEXITCODE -eq 0) { $py = $c; break }
    }
  }
  if (-not $py) {
    if (Winget-Install 'Python.Python.3.12' 'Python 3.12') {
      foreach ($c in @('py', 'python')) { if (Has $c) { $py = $c; break } }
    }
  }
  if ($py) { Ok "$(& $py --version)" } else { Warn 'no Python: wheel buttons and the backup wheel helper will not run (everything else works)' }
}

Step 'Cloudflare tunnel (cloudflared)'
$cf = Get-Command cloudflared -ErrorAction SilentlyContinue
if (-not $cf) {
  foreach ($p in @("${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe", "$env:ProgramFiles\cloudflared\cloudflared.exe")) { if (Test-Path $p) { $cf = $p } }
}
if (-not $cf) { Winget-Install 'Cloudflare.cloudflared' 'cloudflared' | Out-Null; $cf = Get-Command cloudflared -ErrorAction SilentlyContinue }
if ($cf) { Ok 'cloudflared installed (start.bat gives the relay an https address for the iPad app)' }
else { Warn 'no cloudflared: the iPad connects over Wi-Fi instead (no mic/camera in Safari)' }

# ---------------------------------------------------------------- 2. npm install
Step 'npm packages'
npm.cmd install --no-fund --no-audit | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'npm install failed (see above)' }
Ok 'installed'

# ---------------------------------------------------------------- 3. mod
Step 'BeamNG mod'
npm.cmd run mod | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'building the mod failed (see above)' }
$zip = Join-Path $here 'beamng\dist\tesla_bridge.zip'

$candidates = @()
if ($BeamNGUserFolder) { $candidates += $BeamNGUserFolder }
$candidates += (Join-Path $env:LOCALAPPDATA 'BeamNG\BeamNG.drive\current')
$old = Join-Path $env:LOCALAPPDATA 'BeamNG.drive'
if (Test-Path $old) {
  $candidates += Get-ChildItem $old -Directory | Where-Object { $_.Name -match '^\d+\.\d+' } |
    Sort-Object { [version]($_.Name -replace '[^\d.]', '') } -Descending | ForEach-Object { $_.FullName }
}
$userFolder = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $userFolder) {
  Warn "BeamNG user folder not found. Start BeamNG once, or pass -BeamNGUserFolder (launcher > Manage User Folder > Open in Explorer shows it)."
  Warn "Then copy $zip into its mods folder."
} else {
  $mods = Join-Path $userFolder 'mods'
  New-Item -ItemType Directory -Force -Path $mods | Out-Null
  Copy-Item $zip (Join-Path $mods 'tesla_bridge.zip') -Force
  Ok "installed into $mods"
  Warn 'if BeamNG is open: restart it (or reload Lua with Ctrl+L) to load the new mod'
}

# ---------------------------------------------------------------- 3b. the Tesla UI app's BeamNG build
$uiRepo = Join-Path $env:USERPROFILE 'tesla-ui-atv'
if (Test-Path (Join-Path $uiRepo 'package.json')) {
  Step 'Tesla UI app (dist-beamng, served by the relay)'
  Push-Location $uiRepo
  try {
    npm.cmd install --no-fund --no-audit | Out-Host
    npm.cmd run build:beamng | Out-Host
    if (Test-Path (Join-Path $uiRepo 'dist-beamng\index.html')) { Ok "built $uiRepo\dist-beamng" } else { Warn 'build:beamng did not produce dist-beamng' }
  } catch { Warn "could not build the app: $_" } finally { Pop-Location }
} else {
  Warn "no ${uiRepo}: the relay shows the test page at / until the app's dist-beamng exists (or pass --app)"
}

# ---------------------------------------------------------------- 4. companion packages
if ($py) {
  Step 'Wheel companion packages'
  & $py -m pip install --user --quiet --disable-pip-version-check pysdl2 pysdl2-dll websocket-client | Out-Host
  if ($LASTEXITCODE -eq 0) { Ok 'pysdl2, pysdl2-dll, websocket-client' } else { Warn 'pip install failed: wheel buttons will not work until it does' }
}

# ---------------------------------------------------------------- 5. firewall
Step 'Windows Firewall (so the iPad can reach the PC)'
$nodeExe = (Get-Command node).Source
$ruleName = 'Tesla BeamNG bridge (Node)'
$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($existing) { Ok 'rule already there' }
else {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $cmd = "New-NetFirewallRule -DisplayName '$ruleName' -Direction Inbound -Program '$nodeExe' -Action Allow -Profile Private | Out-Null"
  try {
    if ($isAdmin) { Invoke-Expression $cmd }
    else { Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile', '-Command', $cmd }
    if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) { Ok 'Node allowed on private networks' }
    else { Warn 'not added: when Windows asks the first time the relay starts, allow Node on PRIVATE networks' }
  } catch {
    Warn 'not added (admin declined): when Windows asks the first time the relay starts, allow Node on PRIVATE networks'
  }
  Warn 'your Wi-Fi must be set to Private (Settings > Network > Wi-Fi > your network > Private)'
}

# ---------------------------------------------------------------- 6. shortcut
if (-not $NoShortcut) {
  Step 'Desktop shortcut'
  $desktop = [Environment]::GetFolderPath('Desktop')
  $lnk = Join-Path $desktop 'Tesla Bridge.lnk'
  $shell = New-Object -ComObject WScript.Shell
  $s = $shell.CreateShortcut($lnk)
  $s.TargetPath = Join-Path $here 'start.bat'
  $s.WorkingDirectory = $here
  $s.Description = 'Start the Tesla UI <-> BeamNG bridge'
  $s.Save()
  Ok "created $lnk"
}

# ---------------------------------------------------------------- 7. check
Step 'Setup check'
npm.cmd run --silent doctor | Out-Host

Write-Host "`nDone. Next: start BeamNG (West Coast USA, any car), then double-click 'Tesla Bridge' on the desktop." -ForegroundColor Cyan
