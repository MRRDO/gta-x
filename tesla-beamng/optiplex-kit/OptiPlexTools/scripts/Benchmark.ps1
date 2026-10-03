<#
 Facts + quick speed tests + (optionally) the game's real FPS, then plain advice.
   Benchmark.ps1                          facts, CPU/RAM/disk tests, advice
   Benchmark.ps1 -SetGpu Discrete         BeamNG renders on the strong card (R5 340X); restart the game after
   Benchmark.ps1 -SetGpu Integrated       BeamNG renders on the processor's graphics
   Benchmark.ps1 -SampleFps 600 -Label "dGPU 900p"   sample the game's FPS for 10 min (game + Car Mode running)
   Benchmark.ps1 -Compare                 table of every FPS run so far and which GPU setup won
 Only the GPU choice is ever changed (and the old value is saved in reports\tune-undo.json).
#>
param(
  [ValidateSet('', 'Discrete', 'Integrated')][string]$SetGpu = '',
  [int]$SampleFps = 0,
  [string]$Label = '',
  [switch]$Compare
)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$reports = Join-Path $root 'reports'
New-Item -ItemType Directory -Force -Path $reports | Out-Null
. (Join-Path $here 'Collect-Facts.ps1')

function Find-BeamExe {
  $c = @('C:\Program Files (x86)\Steam\steamapps\common\BeamNG.drive\Bin64\BeamNG.drive.x64.exe', 'C:\Program Files\Steam\steamapps\common\BeamNG.drive\Bin64\BeamNG.drive.x64.exe')
  foreach ($p in $c) { if (Test-Path $p) { return $p } }
  $proc = Get-Process BeamNG.drive.x64 -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($proc) { return $proc.Path }
  foreach ($d in (Get-PSDrive -PSProvider FileSystem).Root) { foreach ($rel in @('SteamLibrary\steamapps\common\BeamNG.drive\Bin64\BeamNG.drive.x64.exe', 'Games\BeamNG.drive\Bin64\BeamNG.drive.x64.exe')) { $p = Join-Path $d $rel; if (Test-Path $p) { return $p } } }
  return $null
}

function Save-Undo($key, $old) {
  $f = Join-Path $reports 'tune-undo.json'
  $d = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
  $d | Add-Member -NotePropertyName $key -NotePropertyValue $old -Force
  $d | ConvertTo-Json | Set-Content -Encoding UTF8 $f
}

if ($SetGpu) {
  $exe = Find-BeamExe
  if (-not $exe) { Write-Host 'Could not find BeamNG.drive.x64.exe. Start the game once, then run this again.' -ForegroundColor Yellow; exit 1 }
  $key = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
  New-Item -Path $key -Force | Out-Null
  $old = (Get-ItemProperty -Path $key -Name $exe -ErrorAction SilentlyContinue).$exe
  Save-Undo "gpuPreference:$exe" $old
  # 1 = power saving (the processor's graphics), 2 = high performance (the strongest GPU)
  $val = if ($SetGpu -eq 'Discrete') { 'GpuPreference=2;' } else { 'GpuPreference=1;' }
  Set-ItemProperty -Path $key -Name $exe -Value $val
  Write-Host "BeamNG set to the $SetGpu GPU ($val). Close and restart the game, then sample FPS." -ForegroundColor Green
  exit 0
}

if ($Compare) {
  $runs = Get-ChildItem $reports -Filter 'fps-*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Sort-Object avg -Descending
  if (-not $runs) { Write-Host 'No FPS runs yet. Use -SampleFps.'; exit 0 }
  $runs | Format-Table label, avg, low1, min, max, samples, seconds -AutoSize
  $best = $runs | Select-Object -First 1
  Write-Host "Best average: $($best.label) ($($best.avg) fps, 1% low $($best.low1)). Prefer the run with the best 1% low if it is close." -ForegroundColor Cyan
  exit 0
}

if ($SampleFps -gt 0) {
  $node = (Get-Command node -ErrorAction SilentlyContinue).Source
  if (-not $node) { Write-Host 'Node is not installed (menu 3 installs it).' -ForegroundColor Yellow; exit 1 }
  $lbl = if ($Label) { $Label } else { 'run ' + (Get-Date -Format 'HH:mm') }
  Write-Host "Sampling the game's FPS for $SampleFps s ($lbl). Drive around normally ..."
  $out = & $node (Join-Path $here 'fps-sample.mjs') --seconds $SampleFps --label $lbl
  Write-Host $out
  if ($out) { $out | Set-Content -Encoding UTF8 (Join-Path $reports ("fps-{0}-{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ($lbl -replace '[^A-Za-z0-9]+', '_'))) }
  exit 0
}

# ---------------------------------------------------------------- default: facts + speed tests + advice
Write-Host "`n== Facts" -ForegroundColor Cyan
$facts = Get-Facts
foreach ($k in $facts.Keys) { if ($k -eq 'gpus') { $facts.gpus | ForEach-Object { Write-Host "GPU: $($_.name) | VRAM $($_.vramMB) MB | driver $($_.driver)" } } elseif ($facts[$k] -is [array]) { Write-Host "${k}: $($facts[$k] -join ' ; ')" } else { Write-Host "${k}: $($facts[$k])" } }

Write-Host "`n== Speed tests (about 30 seconds)" -ForegroundColor Cyan
$res = [ordered]@{}
# CPU, one thread: how long a fixed amount of arithmetic takes
$sw = [Diagnostics.Stopwatch]::StartNew(); $x = 0.0; for ($i = 1; $i -le 3000000; $i++) { $x += [math]::Sqrt($i) * 1.0000001 }; $sw.Stop()
$res.cpuSingleMs = $sw.ElapsedMilliseconds
# memory: copy a 256 MB array a few times
$a = New-Object byte[] (256MB); $b = New-Object byte[] (256MB)
$sw = [Diagnostics.Stopwatch]::StartNew(); for ($i = 0; $i -lt 4; $i++) { [Array]::Copy($a, $b, $a.Length) }; $sw.Stop()
$res.ramMBps = [math]::Round((4 * 256) / ($sw.ElapsedMilliseconds / 1000.0))
$a = $null; $b = $null
# disk: write and read 512 MB on C:
$tmp = Join-Path $env:TEMP 'optiplex-bench.bin'; $buf = New-Object byte[] (4MB)
(New-Object Random).NextBytes($buf)
$sw = [Diagnostics.Stopwatch]::StartNew(); $fs = [IO.File]::Create($tmp); for ($i = 0; $i -lt 128; $i++) { $fs.Write($buf, 0, $buf.Length) }; $fs.Flush($true); $fs.Close(); $sw.Stop()
$res.diskWriteMBps = [math]::Round(512 / ($sw.ElapsedMilliseconds / 1000.0))
$sw = [Diagnostics.Stopwatch]::StartNew(); $fs = [IO.File]::OpenRead($tmp); $rb = New-Object byte[] (4MB); while ($fs.Read($rb, 0, $rb.Length) -gt 0) {}; $fs.Close(); $sw.Stop()
$res.diskReadMBps = [math]::Round(512 / ($sw.ElapsedMilliseconds / 1000.0))
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
$res.GetEnumerator() | ForEach-Object { Write-Host ("{0}: {1}" -f $_.Key, $_.Value) }

Write-Host "`n== What I would do" -ForegroundColor Cyan
$adv = @()
$dg = $facts.gpus | Where-Object { $_.name -notmatch 'Intel|Basic|Microsoft' } | Select-Object -First 1
$ig = $facts.gpus | Where-Object { $_.name -match 'Intel' } | Select-Object -First 1
if ($dg -and $dg.vramMB -and $dg.vramMB -le 2048) { $adv += "The card ($($dg.name)) has about $($dg.vramMB) MB of VRAM: keep BeamNG textures on Low/Medium and resolution at 1280x720 to 1600x900." }
if ($dg -and $ig) { $adv += "Two graphics chips found. Plug the monitor into the motherboard port, then test both: Benchmark.ps1 -SetGpu Discrete / Integrated, restart the game, -SampleFps 600, and finally -Compare." }
if ($dg -and -not $ig) { $adv += 'Only one graphics chip is visible. If a monitor is plugged into the motherboard, enable the integrated graphics in the BIOS (Multi-Display).' }
if ($facts.ramChannels -match 'SINGLE') { $adv += 'RAM is a single stick: add a matching second stick (dual channel), it helps the integrated graphics a lot.' }
if ($res.diskReadMBps -lt 200) { $adv += "Disk reads $($res.diskReadMBps) MB/s: this looks like a hard drive. An SSD will help loading and streaming more than anything else." }
if ($res.cpuSingleMs -gt 4000) { $adv += 'The single-thread CPU test was slow: close background apps, check the power plan (menu 2) and CPU temperature (HWiNFO).' }
if ($facts.cDriveFreeGB -lt 40) { $adv += "Only $($facts.cDriveFreeGB) GB free on C:. Free space before installing mods." }
if ($facts.case -match 'SFF|Space|Low-profile|Micro') { $adv += 'Small case: a graphics card must be low-profile and the power supply is small (read the label). Keep the vents clear.' }
if (-not $adv) { $adv += 'Nothing obvious. Next: run the game and sample FPS (-SampleFps 600).' }
$adv | ForEach-Object { Write-Host " - $_" }
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
[pscustomobject]@{ facts = $facts; tests = $res; advice = $adv } | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $reports "benchmark-$($env:COMPUTERNAME)-$stamp.json")
Write-Host "`nSaved to $reports. Send that folder's newest benchmark-*.json to Claude and it will pick the settings." -ForegroundColor Green
