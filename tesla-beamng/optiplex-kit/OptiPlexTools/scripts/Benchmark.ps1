<#
 Facts + quick speed tests + (optionally) the game's real FPS, then plain advice.
   Benchmark.ps1                          facts, CPU/RAM/disk tests, advice
   Benchmark.ps1 -SetGpu Discrete         BeamNG renders on the strong card (R5 340X); restart the game after
   Benchmark.ps1 -SetGpu Integrated       BeamNG renders on the processor's graphics
   Benchmark.ps1 -SampleFps 600 -Label "dGPU 900p"   sample the game's FPS for 10 min (game + Car Mode running)
   Benchmark.ps1 -Compare                 table of every FPS run so far, which GPU setup won, and a verdict
   Benchmark.ps1 -Matrix                  the full test plan (BENCHMARK-PLAN.txt) with what is done and what is left
   Benchmark.ps1 -Soak 5                  CPU stress for N minutes while watching clocks/temperature (heat throttling check)
 Only the GPU choice is ever changed (and the old value is saved in reports\tune-undo.json).
#>
param(
  [ValidateSet('', 'Discrete', 'Integrated')][string]$SetGpu = '',
  [int]$SampleFps = 0,
  [string]$Label = '',
  [switch]$Compare,
  [switch]$Matrix,
  [int]$Soak = 0
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


# Watches the PC while a test runs: CPU use, "processor performance" (drops when it throttles from heat), temperature
# if Windows exposes it, and 3D engine use per graphics chip (which tells you WHICH GPU the game really used).
function Start-Watch($seconds) {
  Start-Job -ArgumentList $seconds -ScriptBlock {
    param($sec)
    $end = (Get-Date).AddSeconds($sec)
    $cpu = @(); $perf = @(); $temp = @(); $gpu = @{}; $ramFree = @()
    while ((Get-Date) -lt $end) {
      try { $c = (Get-Counter '\Processor Information(_Total)\% Processor Utility' -ErrorAction Stop).CounterSamples[0].CookedValue; $cpu += $c } catch {}
      try { $p = (Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples[0].CookedValue; $perf += $p } catch {}
      try { $t = (Get-Counter '\Thermal Zone Information(*)\Temperature' -ErrorAction Stop).CounterSamples | ForEach-Object { $_.CookedValue - 273.15 } | Measure-Object -Maximum; if ($t.Maximum -gt 0 -and $t.Maximum -lt 130) { $temp += $t.Maximum } } catch {}
      try { $ramFree += (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue } catch {}
      try {
        $g = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop).CounterSamples
        $by = $g | Group-Object { if ($_.InstanceName -match 'luid_(0x[0-9a-fA-F]+_0x[0-9a-fA-F]+)') { $Matches[1] } else { 'unknown' } }
        foreach ($grp in $by) { $sum = ($grp.Group | Measure-Object CookedValue -Sum).Sum; if (-not $gpu.ContainsKey($grp.Name)) { $gpu[$grp.Name] = @() }; $gpu[$grp.Name] += $sum }
      } catch {}
      Start-Sleep -Seconds 2
    }
    $avg = { param($a) if ($a.Count) { [math]::Round(($a | Measure-Object -Average).Average, 1) } else { $null } }
    $max = { param($a) if ($a.Count) { [math]::Round(($a | Measure-Object -Maximum).Maximum, 1) } else { $null } }
    $min = { param($a) if ($a.Count) { [math]::Round(($a | Measure-Object -Minimum).Minimum, 1) } else { $null } }
    $gsum = @{}; foreach ($k in $gpu.Keys) { $gsum[$k] = [pscustomobject]@{ avg = (& $avg $gpu[$k]); max = (& $max $gpu[$k]) } }
    [pscustomobject]@{ cpuAvg = (& $avg $cpu); cpuMax = (& $max $cpu); perfMin = (& $min $perf); perfAvg = (& $avg $perf); tempMax = (& $max $temp); ramFreeMinMB = (& $min $ramFree); gpu3d = $gsum }
  }
}
function Get-Verdict($r) {
  if (-not $r.avg) { return '?' }
  if ($r.avg -ge 45 -and $r.low1 -ge 30) { return 'GOOD (45+ avg, 1% low 30+)' }
  if ($r.avg -ge 30 -and $r.low1 -ge 20) { return 'OK (30+ avg): playable, lower a setting or two' }
  return 'TOO SLOW (under 30): lower settings, or the card is the problem'
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


if ($Soak -gt 0) {
  Write-Host "CPU stress for $Soak minute(s) on every thread. Watch for the clock dropping (throttling) and the temperature." -ForegroundColor Cyan
  $n = [Environment]::ProcessorCount
  $w = Start-Watch ($Soak * 60)
  $jobs = 1..$n | ForEach-Object { Start-Job -ArgumentList $Soak -ScriptBlock { param($m) $e = (Get-Date).AddMinutes($m); $x = 0.0; while ((Get-Date) -lt $e) { for ($i = 1; $i -le 200000; $i++) { $x += [math]::Sqrt($i) } } } }
  Wait-Job $w | Out-Null
  $r = Receive-Job $w; Remove-Job $w -Force
  $jobs | Stop-Job -ErrorAction SilentlyContinue; $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
  $r | Format-List
  $verdict = @()
  if ($r.perfMin -ne $null -and $r.perfAvg -ne $null -and $r.perfMin -lt 0.7 * $r.perfAvg) { $verdict += "Clock fell to $($r.perfMin)% of its average: the CPU is THROTTLING. Clean the dust / re-paste / check the fan (small cases get hot)." }
  if ($r.tempMax -ne $null -and $r.tempMax -gt 90) { $verdict += "Hot: $($r.tempMax) C. Fix cooling before tuning anything else." }
  if (-not $verdict) { $verdict += 'No sign of heat throttling in this test.' }
  $verdict | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
  [pscustomobject]@{ soakMinutes = $Soak; watch = $r; verdict = $verdict } | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $reports ("soak-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
  exit 0
}

if ($Matrix) {
  $plan = @(
    @('A1', 'Idle baseline', 'Benchmark.ps1   (facts + quick tests; PC idle, nothing else open)'),
    @('A2', 'Heat check (CPU stress)', 'Benchmark.ps1 -Soak 5'),
    @('B1', 'Low 1280x720, integrated GPU, no traffic', 'Benchmark.ps1 -SetGpu Integrated, restart game, then -SampleFps 300 -Label "iGPU low 720p"'),
    @('B2', 'Low 1280x720, Radeon card, no traffic', 'Benchmark.ps1 -SetGpu Discrete, restart game, then -SampleFps 300 -Label "dGPU low 720p"'),
    @('B3', 'Medium 1600x900, best GPU from B1/B2', '-SampleFps 300 -Label "best med 900p"'),
    @('B4', 'Laptop-copy settings (menu 5), best GPU', '-SampleFps 300 -Label "laptop settings"'),
    @('C1', 'Traffic: 10 cars', '-SampleFps 300 -Label "traffic 10"'),
    @('C2', 'Traffic: 20 cars', '-SampleFps 300 -Label "traffic 20"'),
    @('D1', 'FSD ON along the same route', 'engage FSD, -SampleFps 300 -Label "FSD on"'),
    @('D2', 'FSD OFF, same route, same traffic', '-SampleFps 300 -Label "FSD off"'),
    @('E1', 'Rear + front camera on (iPad)', '-SampleFps 300 -Label "cameras on"'),
    @('F1', '30-minute soak drive (heat + memory)', '-SampleFps 1800 -Label "soak 30"')
  )
  $done = (Get-ChildItem $reports -Filter 'fps-*.json' -ErrorAction SilentlyContinue | ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).label }) -join '|'
  $hasSoak = [bool](Get-ChildItem $reports -Filter 'soak-*.json' -ErrorAction SilentlyContinue)
  foreach ($row in $plan) {
    $label = [regex]::Match($row[2], '-Label "([^"]+)"').Groups[1].Value
    $ok = if ($row[0] -eq 'A2') { $hasSoak } elseif ($label) { $done -match [regex]::Escape($label) } else { [bool](Get-ChildItem $reports -Filter 'benchmark-*.json' -ErrorAction SilentlyContinue) }
    Write-Host ("[{0}] {1}  {2}" -f $(if ($ok) { 'x' } else { ' ' }), $row[0], $row[1]) -ForegroundColor $(if ($ok) { 'Green' } else { 'White' })
    if (-not $ok) { Write-Host "       $($row[2])" -ForegroundColor DarkGray }
  }
  Write-Host "`nSame map, same car, same route, same time of day for every run. Details: BENCHMARK-PLAN.txt"
  exit 0
}

if ($Compare) {
  $runs = Get-ChildItem $reports -Filter 'fps-*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Sort-Object avg -Descending
  if (-not $runs) { Write-Host 'No FPS runs yet. Use -SampleFps.'; exit 0 }
  $runs | ForEach-Object { $_ | Add-Member -NotePropertyName verdict -NotePropertyValue (Get-Verdict $_) -Force; $_ } | Format-Table label, avg, low1, min, max, cpuAvg, perfMin, tempMax, verdict -AutoSize
  $best = $runs | Select-Object -First 1
  Write-Host "Best average: $($best.label) ($($best.avg) fps, 1% low $($best.low1)). Prefer the run with the best 1% low if it is close." -ForegroundColor Cyan
  exit 0
}

if ($SampleFps -gt 0) {
  $node = (Get-Command node -ErrorAction SilentlyContinue).Source
  if (-not $node) { Write-Host 'Node is not installed (menu 3 installs it).' -ForegroundColor Yellow; exit 1 }
  $lbl = if ($Label) { $Label } else { 'run ' + (Get-Date -Format 'HH:mm') }
  Write-Host "Sampling the game's FPS for $SampleFps s ($lbl). Drive around normally ..."
  $watch = Start-Watch $SampleFps
  $out = & $node (Join-Path $here 'fps-sample.mjs') --seconds $SampleFps --label $lbl
  Wait-Job $watch -Timeout 30 | Out-Null
  $w = Receive-Job $watch -ErrorAction SilentlyContinue; Remove-Job $watch -Force -ErrorAction SilentlyContinue
  $res = $null; try { $res = $out | ConvertFrom-Json } catch {}
  if ($res -and $res.avg) {
    if ($w) { foreach ($k in 'cpuAvg', 'cpuMax', 'perfMin', 'tempMax', 'ramFreeMinMB', 'gpu3d') { $res | Add-Member -NotePropertyName $k -NotePropertyValue $w.$k -Force } }
    $res | Add-Member -NotePropertyName verdict -NotePropertyValue (Get-Verdict $res) -Force
    $res | Format-List
    if ($w -and $w.gpu3d) { Write-Host 'GPU 3D use per adapter (the busy one is the one BeamNG really used):'; $w.gpu3d.GetEnumerator() | ForEach-Object { Write-Host "   $($_.Key): avg $($_.Value.avg)%  max $($_.Value.max)%" } }
    $res | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $reports ("fps-{0}-{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ($lbl -replace '[^A-Za-z0-9]+', '_')))
  } else { Write-Host $out }
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
