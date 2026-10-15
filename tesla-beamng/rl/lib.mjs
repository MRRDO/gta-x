// Shared by the soak test and the practice runner: a game screenshot (small JPEG) and the GitHub upload with the black box token.
import { execFile } from 'node:child_process'
import { readFileSync, existsSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

const HOME = join(homedir(), '.tesla-beamng')

/** Screenshot of the primary screen (the game, fullscreen) as a ~960 px wide JPEG. Windows only; resolves true when the file exists. */
export function screenshot(file, width = 960) {
  if (process.platform !== 'win32') return Promise.resolve(false)
  try { mkdirSync(dirname(file), { recursive: true }) } catch {}
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
  return new Promise((res) => execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { windowsHide: true, timeout: 20000 }, () => res(existsSync(file))))
}

export function uploadConfig() {
  let token = (process.env.TESLA_GH_TOKEN || '').trim()
  try { if (!token) token = readFileSync(join(HOME, 'github-token.txt'), 'utf8').trim() } catch {}
  let cfg = {}
  try { cfg = JSON.parse(readFileSync(join(HOME, 'blackbox-upload.json'), 'utf8')) } catch {}
  return { token, repo: cfg.repo || 'MRRDO/tesla-ui-atv', branch: cfg.branch || '' }
}

/** upload(dirInRepo)(relPath, buffer) -> status string. Knows the sha of what it uploaded, and retries once on a 409 / 422 (stale sha). */
export function uploader(dirInRepo) {
  const shas = new Map()
  return async function upload(rel, buf) {
    if (process.env.SOAK_NO_UPLOAD) return 'skipped (SOAK_NO_UPLOAD)'
    const c = uploadConfig()
    if (!c.token) return 'no GitHub token on this PC'
    const path = `${dirInRepo}/${rel}`
    const url = `https://api.github.com/repos/${c.repo}/contents/${path}`
    const headers = { authorization: `Bearer ${c.token}`, accept: 'application/vnd.github+json', 'user-agent': 'tesla-rl' }
    try {
      for (let attempt = 0; attempt < 2; attempt++) {
        const body = { message: `${dirInRepo} ${rel}`, content: Buffer.from(buf).toString('base64') }
        if (c.branch) body.branch = c.branch
        if (shas.has(path)) body.sha = shas.get(path)
        const r = await fetch(url, { method: 'PUT', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(30000) })
        const j = await r.json().catch(() => ({}))
        if (r.ok) { if (j.content?.sha) shas.set(path, j.content.sha); return 'uploaded' }
        if ((r.status === 409 || r.status === 422) && attempt === 0) { // stale or missing sha: ask for the current one
          const g = await fetch(url + (c.branch ? `?ref=${c.branch}` : ''), { headers, signal: AbortSignal.timeout(20000) })
          const gj = await g.json().catch(() => ({}))
          if (gj.sha) shas.set(path, gj.sha)
          continue
        }
        return `GitHub ${r.status}: ${String(j.message || '').slice(0, 80)}`
      }
    } catch (e) { return `not uploaded: ${e.message}`.slice(0, 120) }
    return 'not uploaded'
  }
}
