// Setup checker: `npm run doctor`. Says what's installed, what's running, and how to fix
// what isn't. Safe to run any time (read-only). Exit code 1 when something needed is missing.

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { connect } from 'node:net'
import { beamngModsDirs } from './beamngPaths.ts'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const arg = (name: string) => { const i = process.argv.indexOf(`--${name}`); return i >= 0 ? process.argv[i + 1] : undefined }
const PORT = Number(arg('port') ?? process.env.BRIDGE_PORT ?? 8765)
const GAME_PORT = 8766

let bad = 0
const ok = (msg: string) => console.log(`  ✅ ${msg}`)
const warn = (msg: string, fix?: string) => console.log(`  ⚠️  ${msg}${fix ? `\n      → ${fix}` : ''}`)
const fail = (msg: string, fix: string) => { bad++; console.log(`  ❌ ${msg}\n      → ${fix}`) }
const head = (t: string) => console.log(`\n${t}`)

function tcpOpen(port: number): Promise<boolean> {
  return new Promise((res) => {
    const s = connect({ host: '127.0.0.1', port })
    const done = (v: boolean) => { s.destroy(); res(v) }
    s.once('connect', () => done(true))
    s.once('error', () => done(false))
    setTimeout(() => done(false), 800)
  })
}

function python(): string | null {
  for (const cmd of process.platform === 'win32' ? ['py', 'python', 'python3'] : ['python3', 'python']) {
    const r = spawnSync(cmd, ['--version'], { encoding: 'utf8' })
    if (r.status === 0) return cmd
  }
  return null
}

async function main() {
  console.log('Tesla BeamNG bridge — setup check')

  head('Software')
  const major = Number(process.versions.node.split('.')[0])
  if (major >= 20) ok(`Node ${process.versions.node}`)
  else fail(`Node ${process.versions.node} is too old`, 'install Node 20+ (winget install OpenJS.NodeJS.LTS)')
  if (existsSync(join(root, 'node_modules', 'ws')) && existsSync(join(root, 'node_modules', 'tsx'))) ok('npm packages installed')
  else fail('npm packages missing', 'run: npm install')
  const py = python()
  if (!py) warn('Python not found (only needed for the wheel companion: wheel buttons + backup force feedback)', 'winget install Python.Python.3.12')
  else {
    const r = spawnSync(py, ['-c', 'import sdl2, websocket; print(sdl2.__version__)'], { encoding: 'utf8' })
    if (r.status === 0) ok(`Python + wheel companion packages (${py}, pysdl2 ${r.stdout.trim()})`)
    else warn('wheel companion packages missing', `${py} -m pip install pysdl2 pysdl2-dll websocket-client`)
    if (r.status === 0) {
      const l = spawnSync(py, [join(root, 'bridge', 'wheel_helper.py'), '--list'], { encoding: 'utf8' })
      const lines = (l.stdout || '').trim().split('\n').filter(Boolean)
      if (lines.some((x) => /force feedback/.test(x))) ok(`wheel found: ${lines.find((x) => /force feedback/.test(x))}`)
      else if (lines.length && !/no joysticks/.test(lines[0])) warn(`controllers found but none with force feedback: ${lines.join('; ')}`)
      else warn('no wheel found by SDL', 'plug the G29 in (and install Logitech G HUB)')
    }
  }

  const cfNames = process.platform === 'win32'
    ? [...(process.env.PATH ?? '').split(';').map((d) => join(d, 'cloudflared.exe')), 'C:\\Program Files (x86)\\cloudflared\\cloudflared.exe', 'C:\\Program Files\\cloudflared\\cloudflared.exe']
    : (process.env.PATH ?? '').split(':').map((d) => join(d, 'cloudflared'))
  if (cfNames.some((f) => existsSync(f))) ok('cloudflared installed (https tunnel for the iPad app)')
  else warn('cloudflared not installed: the iPad app connects over Wi-Fi only (no mic/camera in Safari)', 'winget install Cloudflare.cloudflared')

  head('Mod')
  const zip = join(root, 'beamng', 'dist', 'tesla_bridge.zip')
  if (existsSync(zip)) ok(`mod built (${(statSync(zip).size / 1024).toFixed(0)} KB)`)
  else fail('mod not built', 'run: npm run mod')
  if (process.platform === 'win32' || process.env.LOCALAPPDATA || process.env.BEAMNG_USER) {
    const dirs = beamngModsDirs()
    const installed = dirs.map((d) => join(d, 'tesla_bridge.zip')).find((f) => existsSync(f))
    if (!installed) fail('mod not in the BeamNG mods folder', `copy beamng/dist/tesla_bridge.zip into ${dirs[0] ?? '<BeamNG user folder>/mods'} (or run setup.ps1)`)
    else if (existsSync(zip) && readFileSync(installed).equals(readFileSync(zip))) ok(`mod installed: ${installed}`)
    else fail(`installed mod is out of date: ${installed}`, 'run setup.ps1 again (or copy the new zip over it)')
  } else warn('not Windows: skipped the BeamNG mods folder check')

  head('Running')
  const relay = await fetch(`http://127.0.0.1:${PORT}/health`).then((r) => r.json()).catch(() => null) as any
  if (relay) {
    ok(`relay running on :${PORT} (${relay.clients} app${relay.clients === 1 ? '' : 's'} connected)`)
    if (relay.tunnel) ok(`tunnel up: ${relay.tunnel} (scan the QR in the relay window on the iPad)`)
    else warn('no https tunnel right now', 'start.bat starts one (needs cloudflared)')
    if (relay.game) ok(`BeamNG connected${relay.version ? ` (${relay.version})` : ''}${relay.level ? `, level ${relay.level}` : ''}`)
    else warn('BeamNG not connected to the relay', 'start BeamNG, load a level and spawn a car (the console should say "teslaBridge: listening")')
  } else {
    warn(`relay not running on :${PORT}`, 'double-click start.bat (or npm run bridge)')
    if (await tcpOpen(GAME_PORT)) ok('BeamNG is running with the mod (port 8766 open)')
    else warn('BeamNG with the mod not detected (port 8766 closed)', 'start BeamNG and load a level')
  }
  const btn = join(root, 'bridge', 'buttons.json')
  if (existsSync(btn)) {
    try { ok(`wheel buttons mapped: ${Object.entries(JSON.parse(readFileSync(btn, 'utf8'))).map(([a, b]) => `${a}=${b}`).join(', ') || 'none'}`) } catch { warn('bridge/buttons.json unreadable') }
  } else warn('no wheel buttons mapped yet', 'test page (or the app) → Wheel buttons → Set, then press a button')

  console.log(bad ? `\n${bad} thing${bad === 1 ? '' : 's'} to fix.` : '\nAll good.')
  process.exit(bad ? 1 : 0)
}

main()
