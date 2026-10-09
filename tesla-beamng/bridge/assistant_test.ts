import { buildPrompt, parseAdvice, adviseStuck, setAssistantEnabled, assistantStatus } from './assistant.ts'
let ok = 0, bad = 0
const check = (n: string, c: boolean) => { c ? ok++ : (bad++, console.log('FAIL:', n)) }
check('parses a good answer', parseAdvice('{"action":"replan","why":"stale route"}')?.action === 'replan')
check('parses with chatter around the JSON', parseAdvice('Sure! {"action":"wait","why":"pedestrian"} ok')?.action === 'wait')
check('rejects an unknown action', parseAdvice('{"action":"floorIt","why":"x"}') === null)
check('rejects garbage', parseAdvice('nope') === null)
check('prompt lists the options and the scene', buildPrompt({ level: 2 }).includes('askDriver') && buildPrompt({ level: 2 }).includes('"level":2'))
check('on by default', assistantStatus().enabled === true)
process.env.TESLA_LLM_URL = 'http://127.0.0.1:9' // nothing listens: must quietly give null
check('no model running -> no advice, no throw', (await adviseStuck({ level: 2 })) === null)
setAssistantEnabled(false)
check('off -> no advice', (await adviseStuck({ level: 2 })) === null && assistantStatus().enabled === false)
console.log(`${ok} passed, ${bad} failed`)
process.exit(bad ? 1 : 0)
