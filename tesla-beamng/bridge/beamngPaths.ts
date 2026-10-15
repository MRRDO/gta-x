// Where BeamNG keeps its user folder on Windows (docs.beamng.com/support/userfolder).

import { existsSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

/** BeamNG user folders' mods/, newest layout first (docs.beamng.com/support/userfolder). */
export function beamngModsDirs(env = process.env): string[] {
  const out: string[] = []
  if (env.BEAMNG_USER) out.push(join(env.BEAMNG_USER, 'mods'))
  const local = env.LOCALAPPDATA
  if (local) {
    out.push(join(local, 'BeamNG', 'BeamNG.drive', 'current', 'mods'))
    const old = join(local, 'BeamNG.drive')
    if (existsSync(old)) {
      for (const v of readdirSync(old).filter((d) => /^\d+\.\d+/.test(d)).sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))) {
        out.push(join(old, v, 'mods'))
      }
    }
  }
  return out
}

