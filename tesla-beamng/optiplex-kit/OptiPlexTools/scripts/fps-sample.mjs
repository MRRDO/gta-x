// Samples the game's frame rate from the Tesla bridge for N seconds (needs Node 22+, built-in WebSocket).
//   node fps-sample.mjs --seconds 120 --label "dGPU 900p" [--url ws://127.0.0.1:8765]
// Prints one JSON line: { label, seconds, samples, avg, low1, min, max }. low1 = the average of the worst 1 %.
const arg = (n, d) => { const i = process.argv.indexOf('--' + n); return i > 0 ? process.argv[i + 1] : d }
const seconds = Number(arg('seconds', '60'))
const label = arg('label', 'run')
const url = arg('url', 'ws://127.0.0.1:8765')
if (typeof WebSocket === 'undefined') { console.error('Needs Node 22 or newer (built-in WebSocket).'); process.exit(2) }
const fps = []
const ws = new WebSocket(url)
const done = () => {
  try { ws.close() } catch {}
  if (!fps.length) { console.log(JSON.stringify({ label, seconds, samples: 0, error: 'no state with fps received: is BeamNG running with the bridge mod and a car in the world?' })); process.exit(1) }
  const s = [...fps].sort((a, b) => a - b)
  const worst = s.slice(0, Math.max(1, Math.floor(s.length * 0.01)))
  const avg = fps.reduce((a, b) => a + b, 0) / fps.length
  const r = (x) => Math.round(x * 10) / 10
  console.log(JSON.stringify({ label, seconds, samples: fps.length, avg: r(avg), low1: r(worst.reduce((a, b) => a + b, 0) / worst.length), min: r(s[0]), max: r(s[s.length - 1]) }))
  process.exit(0)
}
ws.onmessage = (e) => { try { const m = JSON.parse(String(e.data)); if (m.t === 'state' && typeof m.fps === 'number' && m.fps > 0) fps.push(m.fps) } catch {} }
ws.onerror = () => { console.error('could not reach the bridge at ' + url + ' (start Car Mode first)'); process.exit(3) }
setTimeout(done, seconds * 1000)
