// FSD Assistant: an optional small local LLM (Ollama, llama.cpp server...) that a slow, rare
// situation can be talked over with. It is NOT in the driving loop (20 Hz, milliseconds); it only
// hears about the odd moment where FSD is stuck and can't say why, and answers with ADVICE the app
// shows: wait / replan / creep / ask the driver, plus a few words of why. The car does not act on it.
// On by default; does nothing (and costs nothing) when no local model is running.
//
//   TESLA_LLM_URL    default http://127.0.0.1:11434 (Ollama)
//   TESLA_LLM_MODEL  default llama3.2:1b (any small instruct model; ~1 GB, runs on the CPU)

const URL_BASE = (process.env.TESLA_LLM_URL ?? 'http://127.0.0.1:11434').replace(/\/$/, '')
const MODEL = process.env.TESLA_LLM_MODEL ?? 'llama3.2:1b'
const OPTIONS = ['wait', 'replan', 'creep', 'askDriver'] as const
export type Advice = (typeof OPTIONS)[number]

let enabled = true
let available = false
let checkedAt = 0
let lastAsk = 0

export const setAssistantEnabled = (on: boolean) => { enabled = on }
export const assistantStatus = () => ({ enabled, available, model: MODEL })

async function refresh(): Promise<boolean> {
  if (Date.now() - checkedAt < 60000) return available
  checkedAt = Date.now()
  try {
    const r = await fetch(`${URL_BASE}/api/tags`, { signal: AbortSignal.timeout(800) })
    available = r.ok
  } catch {
    available = false
  }
  return available
}

export function buildPrompt(scene: Record<string, unknown>): string {
  return `You help a self-driving car. It has been stopped for a while and cannot say why.
Scene (JSON): ${JSON.stringify(scene)}
Choose exactly one action from: ${OPTIONS.join(', ')}.
- wait: something legitimate is in the way and will clear
- replan: the route or a stale state is probably the problem
- creep: nothing is in the way, inch forward
- askDriver: it could be unsafe or is unclear
Answer as JSON: {"action":"<one of them>","why":"<at most 12 words>"}`
}

export function parseAdvice(text: string): { action: Advice; why: string } | null {
  try {
    const j = JSON.parse(text.slice(text.indexOf('{'), text.lastIndexOf('}') + 1))
    if (OPTIONS.includes(j.action)) return { action: j.action as Advice, why: String(j.why ?? '').slice(0, 80) }
  } catch {
    /* not JSON: fall through */
  }
  return null
}

/** Ask the model about a stuck FSD. Resolves null when disabled, no model is running, or the answer is unusable. */
export async function adviseStuck(scene: Record<string, unknown>): Promise<{ action: Advice; why: string } | null> {
  if (!enabled || Date.now() - lastAsk < 20000 || !(await refresh())) return null
  lastAsk = Date.now()
  try {
    const r = await fetch(`${URL_BASE}/api/generate`, {
      method: 'POST',
      signal: AbortSignal.timeout(8000),
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: MODEL, prompt: buildPrompt(scene), stream: false, format: 'json', options: { temperature: 0, num_predict: 60 } }),
    })
    if (!r.ok) return null
    return parseAdvice(String(((await r.json()) as { response?: string }).response ?? ''))
  } catch {
    return null
  }
}

