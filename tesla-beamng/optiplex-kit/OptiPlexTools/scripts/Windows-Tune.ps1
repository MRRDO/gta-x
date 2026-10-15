<#
 The Windows tuning list Quentin chose (email #26-#36, #39), asking before each step.
 NOT done on purpose: turning sleep/hibernate off (#31: they stay available, just never automatic),
 transparency/animations (#37), notifications (#38), restore points (#40), auto-login (needs a password).
 Old values are saved in reports\tune-undo.json.  Run as administrator.
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$reports = Join-Path $root 'reports'
New-Item -ItemType Directory -Force -Path $reports | Out-Null
$undoFile = Join-Path $reports 'tune-undo.json'
$undo = if (Test-Path $undoFile) { Get-Content $undoFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
function Remember($k, $v) { $undo | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force; $undo | ConvertTo-Json | Set-Content -Encoding UTF8 $undoFile }
function Ask($q) { $a = Read-Host "$q [Y/n]"; return ($a -eq '' -or $a -match '^[Yy]') }
function SetReg($path, $name, $value, $type = 'DWord') {
  New-Item -Path $path -Force | Out-Null
  $old = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
  Remember "$path|$name" $old
  Set-ItemProperty -Path $path -Name $name -Value $value -Type $type
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Run this from START-HERE.cmd (it asks for administrator rights).' -ForegroundColor Yellow; exit 1 }

if (Ask '1. High performance power plan; sleep and hibernate stay available but never start by themselves?') {
  Remember 'activeScheme' ((powercfg /getactivescheme) -join ' ')
  $hp = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
  if (-not ((powercfg /list) -match $hp)) { powercfg /duplicatescheme $hp | Out-Null }
  powercfg /setactive $hp
  powercfg /change standby-timeout-ac 0      # never sleep by itself
  powercfg /change hibernate-timeout-ac 0    # never hibernate by itself (hibernate itself is NOT switched off)
  Write-Host '   done' -ForegroundColor Green
}
if (Ask '2. Game Mode on, Game Bar and background recording off?') {
  SetReg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
  SetReg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
  SetReg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
  SetReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
  Write-Host '   done' -ForegroundColor Green
}
Write-Host "`n3. Startup apps (listed only, nothing changed). Remove what you do not need in Task Manager > Startup:" -ForegroundColor Cyan
Get-CimInstance Win32_StartupCommand | ForEach-Object { Write-Host "   $($_.Name)  ->  $($_.Command)" }
if (Ask '4. Windows Update: active hours 8:00-23:00 and no automatic driver updates (so the graphics driver you test stays)?') {
  SetReg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursStart' 8
  SetReg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursEnd' 23
  SetReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
  Write-Host '   done' -ForegroundColor Green
}
if (Ask '5. Firewall: allow the Tesla bridge on ports 8765 and 8770 (Private networks only)?') {
  foreach ($p in 8765, 8770) {
    $n = "Tesla bridge $p"
    if (-not (Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName $n -Direction Inbound -Protocol TCP -LocalPort $p -Action Allow -Profile Private | Out-Null }
  }
  Write-Host '   done' -ForegroundColor Green
}
if (Ask '6. Defender exclusions for the BeamNG folders (faster loading)?') {
  $paths = @("$env:LOCALAPPDATA\BeamNG", "$env:LOCALAPPDATA\BeamNG.drive", "$env:USERPROFILE\Documents\BeamNG.drive", "$env:USERPROFILE\Documents\BeamNG", 'C:\car-mode')
  foreach ($d in (Get-PSDrive -PSProvider FileSystem).Root) { foreach ($rel in 'Program Files (x86)\Steam\steamapps\common\BeamNG.drive', 'SteamLibrary\steamapps\common\BeamNG.drive') { $paths += (Join-Path $d $rel) } }
  foreach ($p in $paths) { if (Test-Path $p) { Add-MpPreference -ExclusionPath $p; Write-Host "   excluded $p" } }
}
$ssd = Get-PhysicalDisk | Where-Object { $_.MediaType -eq 'SSD' } | Select-Object -First 1
$free = [math]::Round((Get-PSDrive C).Free / 1GB)
if ($ssd -and $free -gt 60 -and (Ask "7. Fixed 16 GB page file on C: ($free GB free, SSD found)?")) {
  Remember 'pagefile' 'was automatically managed'
  $cs = Get-CimInstance Win32_ComputerSystem; if ($cs.AutomaticManagedPagefile) { $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false } }
  $pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'C:*' }
  if ($pf) { $pf | Set-CimInstance -Property @{ InitialSize = 16384; MaximumSize = 16384 } } else { New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = 'C:\pagefile.sys'; InitialSize = 16384; MaximumSize = 16384 } | Out-Null }
  Write-Host '   done (takes effect after a restart)' -ForegroundColor Green
}
if (Ask '8. Make BeamNG use the high-performance GPU (the R5 340X)? (use Benchmark.ps1 -SetGpu to test both first)') {
  & (Join-Path $here 'Benchmark.ps1') -SetGpu Discrete
}
$carBat = 'C:\car-mode\tesla-beamng\start.bat'
if ((Test-Path $carBat) -and (Ask '9. Start the Tesla bridge (Car Mode) automatically when you log in?')) {
  $act = New-ScheduledTaskAction -Execute $carBat -WorkingDirectory (Split-Path $carBat)
  $trg = New-ScheduledTaskTrigger -AtLogOn
  Register-ScheduledTask -TaskName 'Car Mode' -Action $act -Trigger $trg -Force | Out-Null
  Write-Host '   done' -ForegroundColor Green
}
Write-Host "`nFinished. Old values are in $undoFile." -ForegroundColor Cyan
