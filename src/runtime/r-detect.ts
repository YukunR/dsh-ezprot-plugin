// Local R discovery and silent installation.
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync } from 'node:fs'
import { readdir } from 'node:fs/promises'
import { join } from 'node:path'
import { DEFAULT_MIRRORS, R_VERSION } from './constants.js'
import type { LogSink, RuntimePaths } from './types.js'
import { candidateScriptPaths, downloadFile, pathLookupCommand, spawnString, versionScore, wireKillOnAbort } from './util.js'

export interface RDetectContext extends RuntimePaths {
  /** Explicit rscript override from the plugin config. */
  rscript?: string
}

/** R version string like "4.4", or null when the executable is not R. */
export function rVersion(rscript: string): string | null {
  const out = spawnString(rscript, ['--version'], 20000)
  if (out === null) return null
  const m = /version\s+(\d+)\.(\d+)/.exec(out)
  return m ? `${m[1]}.${m[2]}` : null
}

/** Locate a usable Rscript (config override → plugin-managed → common dirs → PATH). */
export async function detectRscript(ctx: RDetectContext): Promise<string | null> {
  if (ctx.rscript) return ctx.rscript
  const exe = process.platform === 'win32' ? 'Rscript.exe' : 'Rscript'
  const candidates: Array<{ path: string; preferred: boolean }> = []
  for (const c of candidateScriptPaths(ctx.runtimeDir)) {
    if (c.directory) {
      try {
        const dirs = await readdir(c.path)
        for (const d of dirs) {
          candidates.push({
            path: join(c.path, d, 'bin', exe),
            preferred: Boolean(c.preferred) || d === `R-${R_VERSION}` || d === `R_${R_VERSION}`,
          })
        }
      } catch {
        // root does not exist
      }
    } else {
      candidates.push({ path: c.path, preferred: Boolean(c.preferred) })
    }
  }
  let best: string | null = null
  let bestScore = 0
  for (const c of candidates) {
    if (!existsSync(c.path)) continue
    const v = rVersion(c.path)
    if (!v) continue
    const [major, minor] = v.split('.').map(Number)
    let score = versionScore(major, minor)
    if (c.preferred && score > 0) score += 1
    if (score > bestScore) {
      bestScore = score
      best = c.path
    }
  }
  if (bestScore > 0) return best
  const { cmd, target } = pathLookupCommand()
  const onPath = spawnString(cmd, [target], 15000)
  if (onPath) {
    const first = onPath.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)[0]
    if (first) {
      const v = rVersion(first)
      if (v) {
        const [major, minor] = v.split('.').map(Number)
        if (versionScore(major, minor) > 0) return first
      }
    }
  }
  return null
}

/** Download and silently install the pinned R version into the managed dir (no admin). */
export async function installR(ctx: RDetectContext, opts: { onLog?: LogSink; signal?: AbortSignal } = {}): Promise<string> {
  const log: LogSink = opts.onLog ?? (() => {})
  const installer = join(ctx.downloadsDir, `R-${R_VERSION}-win.exe`)
  const installDir = join(ctx.runtimeDir, `R-${R_VERSION}`)
  if (existsSync(join(installDir, 'bin', 'Rscript.exe'))) {
    log(`R ${R_VERSION} already installed at ${installDir}`)
    return join(installDir, 'bin', 'Rscript.exe')
  }
  mkdirSync(ctx.downloadsDir, { recursive: true })
  const urls = [
    `${ctx.rBase}/old/${R_VERSION}/R-${R_VERSION}-win.exe`,
    `${DEFAULT_MIRRORS.fallbackRBase}/old/${R_VERSION}/R-${R_VERSION}-win.exe`,
  ]
  let downloaded = false
  for (const url of urls) {
    try {
      log(`Downloading R ${R_VERSION} installer from ${url} ...`)
      await downloadFile(url, installer)
      downloaded = true
      break
    } catch (error) {
      log(`  failed: ${error instanceof Error ? error.message : String(error)}`)
    }
  }
  if (!downloaded) throw new Error(`cannot download R ${R_VERSION} installer from any mirror`)
  log('Running silent installer (no admin rights required) ...')
  await new Promise<void>((resolvePromise, reject) => {
    const proc = spawn(installer, ['/VERYSILENT', '/CURRENTUSER', `/DIR=${installDir}`, '/NORESTART', '/SUPPRESSMSGBOXES'], {
      windowsHide: true,
    })
    wireKillOnAbort(proc, opts.signal)
    const timer = setTimeout(() => {
      try { proc.kill() } catch { /* already dead */ }
      reject(new Error('R installer timed out after 30 minutes'))
    }, 30 * 60 * 1000)
    proc.on('error', (error) => { clearTimeout(timer); reject(error) })
    proc.on('close', (code) => {
      clearTimeout(timer)
      if (code === 0 && existsSync(join(installDir, 'bin', 'Rscript.exe'))) resolvePromise()
      else reject(new Error(`R installer exited with code ${code}`))
    })
  })
  log(`R ${R_VERSION} installed to ${installDir}`)
  return join(installDir, 'bin', 'Rscript.exe')
}
