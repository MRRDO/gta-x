// The app's in-app Browser: GET /browse?u=<url> fetches a page for it and strips the headers that
// stop sites being shown inside another page (X-Frame-Options, frame-ancestors). Made for reading
// and searching; logins, cookies, POST forms and heavy web apps (YouTube...) do not work.
//
// Safety:
//  * needs the pairing token like the other private endpoints (checked by relay.ts before this runs)
//  * public web only: hosts that resolve to loopback / private / link-local addresses are refused,
//    so it can't be used to reach this PC or the home network; redirects are re-checked
//  * the answer carries `Content-Security-Policy: sandbox allow-scripts allow-forms allow-popups`
//    (no allow-same-origin), so the page runs in an opaque origin and can't read the app's storage
//  * no cookies or credentials are forwarded either way; 8 MB and 15 s limits
import { lookup } from 'node:dns/promises'
import { isIP } from 'node:net'
import type { IncomingMessage, ServerResponse } from 'node:http'

const MAX_BYTES = 8 * 1024 * 1024
const TIMEOUT_MS = 15000
const MAX_REDIRECTS = 5

export function isPrivateAddress(ip: string): boolean {
  const v = isIP(ip)
  if (v === 4) {
    const [a, b] = ip.split('.').map(Number)
    return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224
  }
  if (v === 6) {
    const s = ip.toLowerCase()
    if (s === '::1' || s === '::') return true
    if (s.startsWith('::ffff:')) return isPrivateAddress(s.slice(7))
    return s.startsWith('fc') || s.startsWith('fd') || /^fe[89ab]/.test(s) || s.startsWith('ff')
  }
  return true
}

/** Throws unless the URL is plain http(s) to a public address. */
export async function checkPublic(u: URL): Promise<void> {
  if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new Error('only http and https')
  const host = u.hostname.replace(/^\[|\]$/g, '')
  if (!host || host === 'localhost' || host.endsWith('.local') || host.endsWith('.internal')) throw new Error('not a public address')
  const addrs = isIP(host) ? [{ address: host }] : await lookup(host, { all: true })
  if (!addrs.length || addrs.some((a) => isPrivateAddress(a.address))) throw new Error('not a public address')
}

// Runs inside the page: links and GET forms ask the app to load them through the proxy again
// (the page is sandboxed, so it can't reach the proxy's cookie itself).
const INJECT = `<script>(function(){function go(u){try{parent.postMessage({tbBrowse:'go',url:u},'*')}catch(e){}}
document.addEventListener('click',function(e){var a=e.target&&e.target.closest&&e.target.closest('a[href]');if(!a)return;var h=a.href;if(!/^https?:/i.test(h))return;e.preventDefault();go(h)},true);
document.addEventListener('submit',function(e){var f=e.target;if(!f||(f.method||'get').toLowerCase()!=='get')return;e.preventDefault();var u=new URL(f.action||location.href);new FormData(f).forEach(function(v,k){if(typeof v==='string')u.searchParams.set(k,v)});go(u.href)},true);
window.open=function(u){if(u)go(new URL(u,document.baseURI).href);return null};
try{parent.postMessage({tbBrowse:'title',title:document.title},'*')}catch(e){}})()</script>`

export function inject(html: string, base: string): string {
  const tag = `<base href="${base.replace(/"/g, '&quot;')}">`
  if (/<head[^>]*>/i.test(html)) return html.replace(/<head[^>]*>/i, (m) => m + tag + INJECT)
  return tag + INJECT + html
}

export async function handleBrowse(_req: IncomingMessage, res: ServerResponse, target: string | null): Promise<void> {
  const fail = (code: number, msg: string) => {
    res.writeHead(code, { 'content-type': 'text/html; charset=utf-8', 'content-security-policy': 'sandbox' })
    res.end(`<meta name="viewport" content="width=device-width"><body style="font:16px -apple-system,sans-serif;background:#171717;color:#ddd;padding:32px"><h3>Can't open this page</h3><p>${msg.replace(/</g, '&lt;')}</p>`)
  }
  if (!target) return fail(400, 'No address.')
  let u: URL
  try {
    u = new URL(/^[a-z]+:\/\//i.test(target) ? target : `https://${target}`)
  } catch {
    return fail(400, 'That is not a web address.')
  }
  try {
    let resp: Response | null = null
    for (let i = 0; i <= MAX_REDIRECTS; i++) {
      await checkPublic(u)
      resp = await fetch(u, {
        redirect: 'manual',
        signal: AbortSignal.timeout(TIMEOUT_MS),
        headers: { 'user-agent': 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1', accept: 'text/html,application/xhtml+xml,*/*;q=0.8', 'accept-language': 'en-US,en;q=0.9' },
      })
      const loc = resp.status >= 300 && resp.status < 400 ? resp.headers.get('location') : null
      if (!loc) break
      u = new URL(loc, u)
      if (i === MAX_REDIRECTS) return fail(508, 'Too many redirects.')
    }
    if (!resp) return fail(502, 'No answer.')
    const type = resp.headers.get('content-type') ?? 'application/octet-stream'
    const declared = Number(resp.headers.get('content-length') ?? 0)
    if (declared > MAX_BYTES) return fail(413, 'That page is too large.')
    const buf = Buffer.from(await resp.arrayBuffer())
    if (buf.length > MAX_BYTES) return fail(413, 'That page is too large.')
    const headers: Record<string, string> = { 'content-type': type, 'content-security-policy': 'sandbox allow-scripts allow-forms allow-popups', 'cache-control': 'no-store' }
    if (/text\/html/i.test(type)) {
      const html = inject(buf.toString('utf8'), u.href)
      res.writeHead(resp.status, headers)
      return void res.end(html)
    }
    res.writeHead(resp.status, headers)
    res.end(buf)
  } catch (e) {
    fail(502, e instanceof Error ? (e.name === 'TimeoutError' ? 'The site took too long.' : e.message) : 'Could not load.')
  }
}
