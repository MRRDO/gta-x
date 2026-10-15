// A small JPEG of the primary screen (the game, fullscreen), for the black box: what the car was looking at when you pressed Ctrl+Alt+B.
// Windows only (PowerShell + System.Drawing); resolves true when the file exists. Never throws.
import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'

export function screenshotTo(file: string, width = 960): Promise<boolean> {
  if (process.platform !== 'win32') return Promise.resolve(false)
  const f = file.replace(/'/g, "''")
  const ps = [
    'Add-Type -AssemblyName System.Windows.Forms,System.Drawing',
    '$b=[System.Windows.Forms.SystemInformation]::PrimaryMonitorSize',
    '$bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height',
    '$g=[System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen(0,0,0,0,$bmp.Size)',
    `$w=${width}; $h=[int]($b.Height*$w/$b.Width); $s=New-Object System.Drawing.Bitmap $bmp,$w,$h`,
    "$c=[System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()|Where-Object{$_.MimeType -eq 'image/jpeg'}",
    '$p=New-Object System.Drawing.Imaging.EncoderParameters 1; $p.Param[0]=New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality,[long]60)',
    `$s.Save('${f}',$c,$p)`,
  ].join('; ')
  return new Promise((res) => {
    try { execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { windowsHide: true, timeout: 20000 }, () => res(existsSync(file))) } catch { res(false) }
  })
}
