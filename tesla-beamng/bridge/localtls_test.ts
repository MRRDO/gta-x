import { localTls } from './localtls.ts'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createServer } from 'node:https'
import { request } from 'node:https'
import forge from 'node-forge'

let pass = 0, fail = 0
const ok = (c: unknown, m: string) => { if (c) pass++; else { fail++; console.log('FAIL', m) } }
const dir = mkdtempSync(join(tmpdir(), 'tls-'))
const a = localTls(dir, ['192.168.1.50', 'localhost', 'optiplex.local'])
const b = localTls(dir, ['optiplex.local', 'localhost', '192.168.1.50'])
ok(a.cert === b.cert, 'same names -> same certificate (stable)')
const c = localTls(dir, ['192.168.1.51', 'localhost'])
ok(c.cert !== a.cert && c.ca === a.ca, 'new address -> new certificate, same CA')
const leaf = forge.pki.certificateFromPem(a.cert.split('-----END CERTIFICATE-----')[0] + '-----END CERTIFICATE-----')
const san = (leaf.getExtension('subjectAltName') as { altNames: { ip?: string; value?: string }[] }).altNames
ok(san.some((n) => n.ip === '192.168.1.50') && san.some((n) => n.value === 'optiplex.local'), 'SAN has the IP and the name')
ok((leaf.validity.notAfter.getTime() - Date.now()) / 86400000 < 825, 'valid under 825 days (iOS limit)')
const caCert = forge.pki.certificateFromPem(a.ca)
ok(caCert.verify(leaf), 'leaf is signed by the CA')
// a real handshake that trusts only our CA
const srv = createServer({ key: a.key, cert: a.cert }, (_q, r) => r.end('hi')).listen(0, '127.0.0.1')
await new Promise((r) => srv.once('listening', r))
const port = (srv.address() as { port: number }).port
const body = await new Promise<string>((res) => {
  const q = request({ host: '127.0.0.1', port, ca: a.ca, servername: 'localhost', checkServerIdentity: () => undefined }, (r) => { let d = ''; r.on('data', (x) => (d += x)); r.on('end', () => res(d)) })
  q.on('error', (e) => res('ERR ' + e.message)); q.end()
})
ok(body === 'hi', 'https handshake works when the client trusts the CA (' + body + ')')
srv.close()
console.log(`${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0)
