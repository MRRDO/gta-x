// The relay's --tunnel mode with a stand-in cloudflared: pairing link, and that anything
// arriving through the tunnel (proxy headers) needs the token, with a brute-force limit.
//   npx tsx bridge/tunnel_test.ts

import { spawn, spawnSync, type ChildProcess } from 'node:child_process'
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { WebSocket } from 'ws'

const PORT = 18773
const results: boolean[] = []
const check = (name: string, ok: boolean, info = '') => { results.push(ok); console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${info ? '  (' + info + ')' : ''}`) }
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const cwd = new URL('..', import.meta.url).pathname
const dir = mkdtempSync(join(tmpdir(), 'tunnel-test-'))
const fake = join(dir, 'cloudflared')
writeFileSync(fake, `#!/usr/bin/env node
process.stderr.write('INF Requesting new quick Tunnel on trycloudflare.com...\\n')
setTimeout(() => process.stderr.write('INF |  https://brave-otter-test.trycloudflare.com  |\\n'), 300)
setInterval(() => {}, 1000)
`)
chmodSync(fake, 0o755)
const procs: ChildProcess[] = []
process.on('exit', () => { procs.forEach((p) => p.kill()); rmSync(dir, { recursive: true, force: true }) })

// refuses to go on the internet without the token
{
  const r = spawnSync(process.execPath, ['--import', 'tsx', 'bridge/relay.ts', '--port', String(PORT + 1), '--tunnel', '--no-auth'], { cwd, encoding: 'utf8', timeout: 20000 })
  check('--tunnel with --no-auth is refused', r.status === 1 && /token/.test(r.stderr), r.stderr.trim())
}

const relay = spawn(process.execPath, ['--import', 'tsx', 'bridge/relay.ts', '--port', String(PORT), '--quiet', '--tunnel', '--cloudflared', fake,
  '--feedback-dir', join(dir, 'fb'), '--buttons-file', join(dir, 'b.json')], { cwd })
procs.push(relay)
let out = ''
relay.stdout.on('data', (d) => (out += d))
const base = `http://127.0.0.1:${PORT}`
let health: any = null
for (let i = 0; i < 60 && !health?.tunnel; i++) { await sleep(250); health = await fetch(`${base}/health`).then((r) => r.json()).catch(() => null) }
check('tunnel address picked up', health?.tunnel === 'https://brave-otter-test.trycloudflare.com', health?.tunnel)
const token = /token=([0-9a-f]+)/.exec(out)?.[1] ?? ''
check('token is 16 hex chars', /^[0-9a-f]{16}$/.test(token), token)
check('pairing link opens the live app with the wss bridge', health?.appLink === `https://tesla-ui-atv.tesla-ui-atv.workers.dev/?bridge=${encodeURIComponent(`wss://brave-otter-test.trycloudflare.com/?token=${token}`)}`, health?.appLink)
check('relay prints the pairing link', out.includes(health?.appLink ?? '###'))

const viaTunnel = { 'cf-connecting-ip': '203.0.113.9', 'x-forwarded-for': '203.0.113.9' }
const remoteHealth = await fetch(`${base}/health`, { headers: viaTunnel }).then((r) => r.json())
check('tunnel address/token not shown to remote callers', remoteHealth.tunnel === undefined && remoteHealth.appLink === undefined)
check('voice notes need the token through the tunnel', (await fetch(`${base}/feedback`, { headers: viaTunnel })).status === 401)
check('...and work with it', (await fetch(`${base}/feedback?token=${token}`, { headers: viaTunnel })).status === 200)
check('voice notes still open from this PC', (await fetch(`${base}/feedback`)).status === 200)

const tryWs = (q: string, headers: Record<string, string>) => new Promise<string>((res) => {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/${q}`, { headers })
  ws.once('open', () => { ws.close(); res('open') })
  ws.once('unexpected-response', (_req, r) => res(String(r.statusCode)))
  ws.once('error', () => res('error'))
})
check('WebSocket through the tunnel without token: 401', (await tryWs('', viaTunnel)) === '401')
check('WebSocket through the tunnel with token: open', (await tryWs(`?token=${token}`, viaTunnel)) === 'open')
// the QR link (?token=) leaves a cookie; the app's own same-origin WebSocket then gets in with it
{
  const r = await fetch(`${base}/?token=${token}`, { headers: viaTunnel })
  const cookie = r.headers.get('set-cookie') ?? ''
  check('pairing link sets a secure, http-only cookie', cookie.includes(`tb_token=${token}`) && /Secure/.test(cookie) && /HttpOnly/.test(cookie), cookie)
  check('WebSocket through the tunnel with only the cookie: open', (await tryWs('', { ...viaTunnel, cookie: `tb_token=${token}` })) === 'open')
  check('a wrong cookie is refused', (await tryWs('', { ...viaTunnel, cookie: 'tb_token=0123456789abcdef' })) === '401')
}
const attacker = { 'cf-connecting-ip': '198.51.100.7' }
for (let i = 0; i < 10; i++) await tryWs('?token=0000000000000000', attacker)
check('after 10 wrong tokens the address is blocked', (await tryWs(`?token=${token}`, attacker)) === '401')
check('other addresses unaffected', (await tryWs(`?token=${token}`, viaTunnel)) === 'open')

const failed = results.filter((r) => !r).length
console.log(`\n${results.length - failed} passed, ${failed} failed`)
process.exit(failed ? 1 : 0)
