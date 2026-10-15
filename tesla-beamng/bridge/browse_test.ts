// Guards of the in-app browser proxy (no network needed).
import { isPrivateAddress, checkPublic, handleBrowse, inject } from './browse.ts'

let ok = 0, bad = 0
const check = (name: string, cond: boolean) => { cond ? ok++ : (bad++, console.log('FAIL:', name)) }

for (const ip of ['127.0.0.1', '10.1.2.3', '172.16.0.1', '172.31.255.1', '192.168.1.1', '169.254.1.1', '0.0.0.0', '100.64.0.1', '::1', 'fd12::1', 'fe80::1', '::ffff:10.0.0.1', '224.0.0.1'])
  check(`private: ${ip}`, isPrivateAddress(ip))
for (const ip of ['8.8.8.8', '1.1.1.1', '172.32.0.1', '2606:4700::1111'])
  check(`public: ${ip}`, !isPrivateAddress(ip))

const rejects = async (u: string) => { try { await checkPublic(new URL(u)); return false } catch { return true } }
for (const u of ['http://localhost/', 'http://127.0.0.1:8765/health', 'http://192.168.0.5/', 'http://[::1]/', 'file:///etc/passwd', 'ftp://example.com/', 'http://printer.local/', 'http://10.0.0.1/'])
  check(`refuses ${u}`, await rejects(u))
check('accepts a public IP', !(await rejects('https://8.8.8.8/')))

// handleBrowse answers 400 / 502 without touching the network for bad input
async function run(target: string | null) {
  let code = 0, body = ''
  const res: any = { writeHead: (c: number) => { code = c }, end: (b?: string) => { body = String(b ?? '') } }
  await handleBrowse({} as any, res, target)
  return { code, body }
}
check('no address -> 400', (await run(null)).code === 400)
check('loopback target -> 502 refused', (await run('http://127.0.0.1:8765/health')).code === 502)
check('the relay itself is unreachable through it', (await run('localhost:8765')).code === 502)

const html = inject('<html><head><title>x</title></head><body><a href="/a">a</a></body></html>', 'https://example.com/p')
check('injects a base tag and the link script', html.includes('<base href="https://example.com/p">') && html.includes('tbBrowse'))
check('page without <head> still gets it', inject('<p>hi</p>', 'https://e.com/').startsWith('<base'))
console.log(`${ok} passed, ${bad} failed`)
process.exit(bad ? 1 : 0)
