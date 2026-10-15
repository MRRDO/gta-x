<#
 Learns from your driving ONLY when you switched it on AND the PC is idle (no keyboard/mouse/wheel for N minutes).
 Any input stops it at once. It runs at low priority so it can never slow the game.
   Train-WhenIdle.ps1 -On       switch on and start waiting (leave this window open, or it runs from the task)
   Train-WhenIdle.ps1 -Off      switch off
 What it runs: python rl\train_bc.py on the logs the bridge recorded with --record (see rl\README.md).
#>
param([switch]$On, [switch]$Off, [int]$IdleMinutes = 10)
$flag = 'C:\car-mode\training.on'
if ($Off) { Remove-Item $flag -Force -ErrorAction SilentlyContinue; Write-Host 'Training switched OFF.' -ForegroundColor Yellow; exit 0 }
if ($On) { New-Item -ItemType File -Force -Path $flag | Out-Null; Write-Host 'Training switched ON. It will start after the PC has been idle.' -ForegroundColor Green }
if (-not (Test-Path $flag)) { Write-Host 'Training is off (use -On).'; exit 0 }
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class IdleTime {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  public static double Seconds() { var i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(i); GetLastInputInfo(ref i); return (Environment.TickCount - i.dwTime) / 1000.0; }
}
'@
$py = (Get-Command py -ErrorAction SilentlyContinue).Source; if (-not $py) { $py = (Get-Command python -ErrorAction SilentlyContinue).Source }
$script = 'C:\car-mode\tesla-beamng\rl\train_bc.py'
if (-not $py -or -not (Test-Path $script)) { Write-Host 'Python or rl\train_bc.py not found (install Car Mode first).' -ForegroundColor Yellow; exit 1 }
$proc = $null
Write-Host "Waiting for $IdleMinutes minutes of idle time. Press Ctrl+C to stop."
while (Test-Path $flag) {
  $idle = [IdleTime]::Seconds()
  if ($proc -and $proc.HasExited) { Write-Host "Training finished (exit $($proc.ExitCode))."; $proc = $null; Start-Sleep -Seconds 600 }
  if (-not $proc -and $idle -ge ($IdleMinutes * 60)) {
    Write-Host 'Idle: training started.'
    $proc = Start-Process -FilePath $py -ArgumentList @($script, '--out', 'C:\car-mode\policy.json') -WorkingDirectory 'C:\car-mode\tesla-beamng' -PassThru -WindowStyle Hidden
    try { $proc.PriorityClass = 'BelowNormal' } catch {}
  }
  if ($proc -and -not $proc.HasExited -and $idle -lt 5) { Write-Host 'You are back: training stopped.'; Stop-Process -Id $proc.Id -Force; $proc = $null }
  Start-Sleep -Seconds 5
}
if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
