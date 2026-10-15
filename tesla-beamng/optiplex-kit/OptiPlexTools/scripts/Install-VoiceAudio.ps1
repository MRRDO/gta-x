<#
 Voice assistant + sound outputs for the Tesla bridge. Asks before each step. Never types a password.
   1. ffmpeg + whisper.cpp + a small English model   -> offline speech to text (bridge/stt.ts)
   2. Ollama + a small model                         -> the AI that understands what you meant (bridge/assistant.ts)
   3. AudioDeviceCmdlets (PowerShell module)         -> list / pick the game and music outputs (bridge/audio.ts)
   4. Equalizer APO (you click through its installer once, pick the music output in its Configurator)
      -> the EQ on the music output, system level. This script then lets the bridge write tesla-eq.txt and adds
         "Include: tesla-eq.txt" to its config.txt.
   5. Tells the bridge where everything is (user environment variables), restart the bridge afterwards.
 Written without a Windows machine: UNTESTED. Run it, read what it prints, and tell the laptop session what broke.
#>
$ErrorActionPreference = 'Continue'
function Ask($q) { (Read-Host "$q (y/n)") -match '^[yY]' }
$tools = 'C:\car-mode-tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null

if (Ask 'Install ffmpeg (winget)') { winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements }

if (Ask 'Download whisper.cpp + the base.en model (about 150 MB)') {
  $w = Join-Path $tools 'whisper'
  New-Item -ItemType Directory -Force -Path $w | Out-Null
  try {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest' -Headers @{ 'User-Agent' = 'optiplex-kit' }
    $asset = $rel.assets | Where-Object { $_.name -match 'whisper-bin-x64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'no whisper-bin-x64.zip in the latest release; download a Windows build from github.com/ggml-org/whisper.cpp/releases by hand into ' + $w }
    Invoke-WebRequest $asset.browser_download_url -OutFile "$w\whisper.zip"
    Expand-Archive "$w\whisper.zip" -DestinationPath $w -Force
    Invoke-WebRequest 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin' -OutFile "$w\ggml-base.en.bin"
    $cli = Get-ChildItem $w -Recurse -Include 'whisper-cli.exe', 'main.exe' | Select-Object -First 1
    if ($cli) {
      [Environment]::SetEnvironmentVariable('WHISPER_BIN', $cli.FullName, 'User')
      [Environment]::SetEnvironmentVariable('WHISPER_MODEL', "$w\ggml-base.en.bin", 'User')
      Write-Host "WHISPER_BIN = $($cli.FullName)" -ForegroundColor Green
    } else { Write-Host 'Could not find whisper-cli.exe after unzipping.' -ForegroundColor Yellow }
  } catch { Write-Host "whisper step failed: $_" -ForegroundColor Yellow }
}

if (Ask 'Install Ollama and pull a small model (llama3.2:3b, about 2 GB)') {
  winget install -e --id Ollama.Ollama --accept-source-agreements --accept-package-agreements
  Write-Host 'Starting Ollama and pulling the model (this can take a while)...'
  $ol = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
  if (Test-Path $ol) { & $ol pull llama3.2:3b } else { Write-Host 'Open a new terminal after the install and run:  ollama pull llama3.2:3b' -ForegroundColor Yellow }
  Write-Host 'To test the GPU (Radeon) instead of the CPU for it, see docs/AI_COMPUTE_PLAN.md (llama.cpp Vulkan).'
}

if (Ask 'Install the AudioDeviceCmdlets PowerShell module (output picker)') {
  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
  Install-Module AudioDeviceCmdlets -Scope CurrentUser -Force
  Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback' } | Format-Table Index, Default, Name -AutoSize
}

if (Ask 'Set up Equalizer APO for the music output (download from sourceforge.net/projects/equalizerapo yourself, run it, tick ONLY the 3.5 mm / Realtek output in its device list)') {
  $cfg = 'C:\Program Files\EqualizerAPO\config'
  if (-not (Test-Path $cfg)) { Write-Host "Not found: $cfg. Install Equalizer APO first, then run this step again." -ForegroundColor Yellow }
  else {
    # needs admin: lets the bridge (a normal user) write the EQ file, and makes APO read it
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'Run this window as administrator for this step.' -ForegroundColor Yellow }
    else {
      icacls $cfg /grant 'Users:(OI)(CI)M' | Out-Null
      if (-not (Test-Path "$cfg\tesla-eq.txt")) { Set-Content "$cfg\tesla-eq.txt" 'Preamp: 0 dB' }
      $main = Get-Content "$cfg\config.txt" -Raw
      if ($main -notmatch 'tesla-eq\.txt') { Add-Content "$cfg\config.txt" "`r`nInclude: tesla-eq.txt" }
      Write-Host 'Equalizer APO will now read tesla-eq.txt (the bridge writes it from the app EQ).' -ForegroundColor Green
    }
  }
}

Write-Host "`nDone. Restart the Tesla Bridge. In the app: Settings > Audio > PC outputs: pick Game = TV (HDMI), Music = the 3.5 mm jack, press Test on each." -ForegroundColor Cyan
Write-Host 'Chrome is needed for Apple Music on the PC (menu 3 installs it). The first time, sign in to Apple Music yourself in the player window that opens.'
