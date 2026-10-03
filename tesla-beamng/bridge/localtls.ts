// Local https for the home Wi-Fi: the iPad only lets a page use its camera and microphone over https, and a
// Cloudflare quick tunnel changes its address every start. So the relay makes its own tiny certificate
// authority once, signs a certificate for this PC's addresses, and the iPad trusts that authority once
// (download /ca.crt in Safari, install it, then switch it on under Settings > General > About > Certificate
// Trust Settings). After that https://<pc-ip>:8443 is a normal secure page that never changes.
import forge from 'node-forge'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const pki = forge.pki
const DAY = 86400000

function newKeys() {
  return pki.rsa.generateKeyPair({ bits: 2048 })
}

function serial() {
  return forge.util.bytesToHex(forge.random.getBytesSync(8)).replace(/^0+/, '1')
}

function makeCa() {
  const keys = newKeys()
  const cert = pki.createCertificate()
  cert.publicKey = keys.publicKey
  cert.serialNumber = serial()
  cert.validity.notBefore = new Date(Date.now() - DAY)
  cert.validity.notAfter = new Date(Date.now() + 3650 * DAY)
  const attrs = [{ name: 'commonName', value: 'Tesla bridge local CA' }, { name: 'organizationName', value: 'Tesla UI bridge (this PC only)' }]
  cert.setSubject(attrs)
  cert.setIssuer(attrs)
  cert.setExtensions([
    { name: 'basicConstraints', cA: true, critical: true },
    { name: 'keyUsage', keyCertSign: true, cRLSign: true, critical: true },
    { name: 'subjectKeyIdentifier' },
  ])
  cert.sign(keys.privateKey, forge.md.sha256.create())
  return { cert, key: keys.privateKey }
}

export type Tls = { key: string; cert: string; ca: string; sans: string[] }

/** The certificate for these names/addresses, signed by the local CA (both kept in `dir`). */
export function localTls(dir: string, names: string[]): Tls {
  mkdirSync(dir, { recursive: true })
  const caCertPath = join(dir, 'ca.crt')
  const caKeyPath = join(dir, 'ca.key')
  let ca: ReturnType<typeof makeCa>
  if (existsSync(caCertPath) && existsSync(caKeyPath)) {
    ca = { cert: pki.certificateFromPem(readFileSync(caCertPath, 'utf8')), key: pki.privateKeyFromPem(readFileSync(caKeyPath, 'utf8')) }
  } else {
    ca = makeCa()
    writeFileSync(caCertPath, pki.certificateToPem(ca.cert))
    writeFileSync(caKeyPath, pki.privateKeyToPem(ca.key), { mode: 0o600 })
  }
  const sans = [...new Set(names.filter(Boolean))].sort()
  const leafPath = join(dir, 'server.json')
  try {
    const old = JSON.parse(readFileSync(leafPath, 'utf8')) as { sans: string[]; key: string; cert: string; notAfter: number }
    if (old.notAfter - Date.now() > 30 * DAY && JSON.stringify(old.sans) === JSON.stringify(sans)) return { key: old.key, cert: old.cert, ca: pki.certificateToPem(ca.cert), sans }
  } catch { /* make a new one */ }
  const keys = newKeys()
  const cert = pki.createCertificate()
  cert.publicKey = keys.publicKey
  cert.serialNumber = serial()
  cert.validity.notBefore = new Date(Date.now() - DAY)
  cert.validity.notAfter = new Date(Date.now() + 800 * DAY) // iOS rejects server certificates valid for more than 825 days
  cert.setSubject([{ name: 'commonName', value: sans[0] ?? 'localhost' }])
  cert.setIssuer(ca.cert.subject.attributes)
  cert.setExtensions([
    { name: 'basicConstraints', cA: false },
    { name: 'keyUsage', digitalSignature: true, keyEncipherment: true, critical: true },
    { name: 'extKeyUsage', serverAuth: true },
    { name: 'subjectAltName', altNames: sans.map((s) => (/^\d+\.\d+\.\d+\.\d+$/.test(s) ? { type: 7, ip: s } : { type: 2, value: s })) },
  ])
  cert.sign(ca.key, forge.md.sha256.create())
  const out = { sans, key: pki.privateKeyToPem(keys.privateKey), cert: pki.certificateToPem(cert) + pki.certificateToPem(ca.cert), notAfter: cert.validity.notAfter.getTime() }
  writeFileSync(leafPath, JSON.stringify(out), { mode: 0o600 })
  return { key: out.key, cert: out.cert, ca: pki.certificateToPem(ca.cert), sans }
}

/** What to tell the person holding the iPad. */
export const setupPage = (host: string, port: number) => `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Trust this PC</title><body style="font:17px -apple-system,sans-serif;max-width:560px;margin:24px auto;padding:0 16px;line-height:1.45">
<h2>One-time setup on the iPad</h2>
<p>This lets the iPad open the car app over a secure address, which is what turns on the camera and microphone.</p>
<ol>
<li><a href="/ca.crt">Download the certificate</a> (tap Allow).</li>
<li>Settings &gt; <b>Profile Downloaded</b> (top of Settings) &gt; Install.</li>
<li>Settings &gt; General &gt; About &gt; <b>Certificate Trust Settings</b> &gt; switch on <i>Tesla bridge local CA</i>.</li>
<li>Open <a href="https://${host}:${port}/">https://${host}:${port}/</a> (add it to the Home Screen).</li>
</ol>
<p style="color:#666">Only do this on your own iPad. The certificate only vouches for this PC's address on your Wi-Fi.</p></body>`
