<#
 Read-only. Collects what we need to decide GPU / settings (email idea #97): CPU, RAM type and channels,
 GPUs with real VRAM, the video connector each monitor is plugged into, disks, case type, BIOS, Windows.
 Writes reports\facts-<PC>-<date>.txt and .json. Dot-source it or run it directly.
#>
$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reports = Join-Path (Split-Path -Parent $here) 'reports'
New-Item -ItemType Directory -Force -Path $reports | Out-Null

function Get-Facts {
  $f = [ordered]@{}
  $os = Get-CimInstance Win32_OperatingSystem
  $cs = Get-CimInstance Win32_ComputerSystem
  $bios = Get-CimInstance Win32_BIOS
  $f.computer = $env:COMPUTERNAME
  $f.model = "$($cs.Manufacturer) $($cs.Model)"
  $f.bios = "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))"
  $f.windows = "$($os.Caption) build $($os.BuildNumber)"
  $enc = (Get-CimInstance Win32_SystemEnclosure).ChassisTypes
  $encNames = @{ 3 = 'Desktop'; 4 = 'Low-profile desktop'; 6 = 'Mini tower'; 7 = 'Tower'; 15 = 'Space-saving (SFF)'; 16 = 'Lunch box'; 35 = 'Mini PC (Micro)'; 31 = 'Laptop convertible'; 9 = 'Laptop'; 10 = 'Notebook' }
  $f.case = ($enc | ForEach-Object { if ($encNames.ContainsKey([int]$_)) { $encNames[[int]$_] } else { "type $_" } }) -join ', '

  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  $f.cpu = "$($cpu.Name.Trim()) | $($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads | max $($cpu.MaxClockSpeed) MHz"

  $dimms = @(Get-CimInstance Win32_PhysicalMemory)
  $memType = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5' }
  $totalGb = [math]::Round(($dimms | Measure-Object Capacity -Sum).Sum / 1GB, 1)
  $f.ram = "$totalGb GB in $($dimms.Count) stick(s)"
  $f.ramDetail = ($dimms | ForEach-Object {
      $t = if ($memType.ContainsKey([int]$_.SMBIOSMemoryType)) { $memType[[int]$_.SMBIOSMemoryType] } else { "type $($_.SMBIOSMemoryType)" }
      "$($_.DeviceLocator): $([math]::Round($_.Capacity / 1GB)) GB $t $($_.ConfiguredClockSpeed) MHz" }) -join ' ; '
  $f.ramChannels = if ($dimms.Count -ge 2) { 'probably dual channel (check the two sticks match and sit in the right slots)' } else { 'SINGLE stick = single channel: slows the integrated graphics. Add a matching second stick.' }

  $gpus = @()
  Get-CimInstance Win32_VideoController | ForEach-Object {
    $vram = $_.AdapterRAM
    # AdapterRAM is capped at 4 GB; the real number is filled in from the registry below
    $gpus += [pscustomobject]@{ name = $_.Name; vramMB = if ($vram) { [math]::Round($vram / 1MB) } else { $null }; driver = $_.DriverVersion; date = $_.DriverDate; status = $_.Status; mode = "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)@$($_.CurrentRefreshRate)" }
  }
  # accurate VRAM from the registry (qwMemorySize), matched by name
  $cls = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty $_.PSPath }
  foreach ($g in $gpus) {
    $m = $cls | Where-Object { $_.DriverDesc -eq $g.name -and $_.'HardwareInformation.qwMemorySize' } | Select-Object -First 1
    if ($m) { $g.vramMB = [math]::Round([double]$m.'HardwareInformation.qwMemorySize' / 1MB) }
  }
  $f.gpus = $gpus

  $outTech = @{ -2 = 'uninitialised'; -1 = 'other'; 0 = 'VGA'; 1 = 'S-Video'; 2 = 'composite'; 3 = 'component'; 4 = 'DVI'; 5 = 'HDMI'; 6 = 'LVDS'; 8 = 'D-Jpn'; 9 = 'SDI'; 10 = 'DisplayPort'; 11 = 'DisplayPort (embedded)'; 12 = 'UDI'; 13 = 'UDI (embedded)'; 14 = 'SDTV dongle'; 15 = 'Miracast'; 2147483648 = 'internal' }
  $mons = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams)
  $f.monitorConnections = ($mons | ForEach-Object { $t = [int64]$_.VideoOutputTechnology; if ($outTech.ContainsKey($t)) { $outTech[$t] } else { "code $t" } }) -join ', '

  $f.disks = @(Get-PhysicalDisk | ForEach-Object { "$($_.FriendlyName): $($_.MediaType) $([math]::Round($_.Size / 1GB)) GB" })
  $f.cDriveFreeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
  $f.network = @(Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object { "$($_.Name): $($_.LinkSpeed)" })
  $f.powerPlan = (powercfg /getactivescheme) -join ' '
  $f.psuNote = 'Not readable by software: open the case and read the label on the power supply (watts).'
  $f.time = (Get-Date).ToString('s')
  $f
}

if ($MyInvocation.InvocationName -ne '.') {
  $facts = Get-Facts
  $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
  $json = Join-Path $reports "facts-$($env:COMPUTERNAME)-$stamp.json"
  $txt = Join-Path $reports "facts-$($env:COMPUTERNAME)-$stamp.txt"
  $facts | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $json
  $lines = @()
  foreach ($k in $facts.Keys) {
    if ($k -eq 'gpus') { foreach ($g in $facts.gpus) { $lines += "GPU: $($g.name) | VRAM $($g.vramMB) MB | driver $($g.driver) | $($g.mode) | $($g.status)" } }
    elseif ($facts[$k] -is [array]) { $lines += "${k}: " + ($facts[$k] -join ' ; ') }
    else { $lines += "${k}: $($facts[$k])" }
  }
  $lines | Set-Content -Encoding UTF8 $txt
  $lines
  Write-Host "`nSaved: $txt" -ForegroundColor Green
}
