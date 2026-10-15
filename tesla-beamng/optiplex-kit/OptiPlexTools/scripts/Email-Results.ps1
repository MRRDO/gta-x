<#
 Shows the newest benchmark / heat-check / FPS results on screen and prepares an email to Quentin with the specs and results.
 It does NOT send anything by itself and never stores a password: it opens a ready-written Gmail message (or your mail app)
 in the browser, and you press Send. The full report is also copied to the clipboard and saved as a .txt in reports\.
   Email-Results.ps1                 newest results, to the default address
   Email-Results.ps1 -To a@b.com     another address
   Email-Results.ps1 -NoOpen         show + save + copy only
#>
param([string]$To = 'quentincpullum@gmail.com', [switch]$NoOpen)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reports = Join-Path (Split-Path -Parent $here) 'reports'
function Newest($filter) { if (Test-Path $reports) { Get-ChildItem $reports -Filter $filter -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 } }
function Load($f) { if ($f) { try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { $null } } }

$bench = Load (Newest 'benchmark-*.json')
$soak = Load (Newest 'soak-*.json')
$fps = Load (Newest 'fps-*.json')
if (-not $bench -and -not $soak -and -not $fps) { Write-Host 'No results yet. Run menu 1 (facts + benchmark) first.' -ForegroundColor Yellow; exit 1 }

$short = New-Object System.Collections.Generic.List[string]
$full = New-Object System.Collections.Generic.List[string]
function Add($s, [switch]$Long) { if (-not $Long) { $short.Add($s) }; $full.Add($s) }
$short.Add("OptiPlex results $(Get-Date -Format 'yyyy-MM-dd HH:mm')"); $full.Add($short[0]); Add ''
if ($bench) {
  $f = $bench.facts; $t = $bench.tests
  Add "SPECS"
  foreach ($k in 'computer', 'model', 'bios', 'windows', 'cpu', 'ram') { if ($f.$k) { Add "  ${k}: $($f.$k)" } }
  if ($f.ramDetail) { Add "  ramDetail: $(@($f.ramDetail) -join ' ; ')" -Long }
  if ($f.ramChannels) { Add "  ramChannels: $($f.ramChannels)" }
  foreach ($g in @($f.gpus)) { if ($g) { Add "  GPU: $($g.name) | VRAM $($g.vramMB) MB | driver $($g.driver)" } }
  if ($f.monitorConnections) { Add "  monitors: $(@($f.monitorConnections) -join ' ; ')" }
  if ($f.disks) { Add "  disks: $(@($f.disks) -join ' ; ')" }
  if ($f.cDriveFreeGB -ne $null) { Add "  C: free GB: $($f.cDriveFreeGB)" }
  if ($f.network) { Add "  network: $(@($f.network) -join ' ; ')" -Long }
  if ($f.powerPlan) { Add "  powerPlan: $($f.powerPlan)" -Long }
  Add ''
  Add "SPEED TESTS"
  Add "  CPU single-thread: $($t.cpuSingleMs) ms (lower is faster)"
  Add "  RAM copy: $($t.ramMBps) MB/s"
  Add "  Disk write: $($t.diskWriteMBps) MB/s   read: $($t.diskReadMBps) MB/s"
  Add ''
  Add "ADVICE"; foreach ($a in @($bench.advice)) { Add "  - $a" }; Add ''
}
if ($soak) {
  $w = $soak.watch
  Add "HEAT CHECK ($($soak.soakMinutes) min CPU stress)"
  Add "  CPU use avg/max: $($w.cpuAvg) / $($w.cpuMax) %   clock min/avg: $($w.perfMin) / $($w.perfAvg) %   max temp: $($w.tempMax) C   RAM free min: $($w.ramFreeMinMB) MB"
  foreach ($v in @($soak.verdict)) { Add "  - $v" }; Add ''
}
if ($fps) {
  Add "NEWEST GAME FPS RUN: $($fps.label)"
  Add "  avg $($fps.avg) fps  1% low $($fps.low1)  min $($fps.min)  max $($fps.max)  CPU avg $($fps.cpuAvg) %  max temp $($fps.tempMax) C"
  foreach ($v in @($fps.verdict)) { Add "  - $v" }; Add ''
}
$shortText = ($short -join "`r`n"); $fullText = ($full -join "`r`n")

Write-Host "`n================ RESULTS ================" -ForegroundColor Cyan
Write-Host $fullText
Write-Host '=========================================' -ForegroundColor Cyan

$txt = Join-Path $reports ("results-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$fullText | Set-Content -Encoding UTF8 $txt
try { Set-Clipboard -Value $fullText; Write-Host 'Full report copied to the clipboard.' -ForegroundColor Green } catch {}
Write-Host "Saved: $txt"
if ($NoOpen) { exit 0 }

$subject = "OptiPlex specs + results ($env:COMPUTERNAME)"
$body = $shortText + "`r`n`r`n(Full report is in your clipboard / saved at $txt : paste it here with Ctrl+V.)"
if ($body.Length -gt 1500) { $body = $body.Substring(0, 1500) + '...' }
$gmail = 'https://mail.google.com/mail/?view=cm&fs=1&to=' + [uri]::EscapeDataString($To) + '&su=' + [uri]::EscapeDataString($subject) + '&body=' + [uri]::EscapeDataString($body)
Write-Host "`nOpening a ready-written email to $To in your browser. Sign in to Gmail if asked, then press Send." -ForegroundColor Cyan
try { Start-Process $gmail } catch { Start-Process ('mailto:' + $To + '?subject=' + [uri]::EscapeDataString($subject) + '&body=' + [uri]::EscapeDataString($body)) }
