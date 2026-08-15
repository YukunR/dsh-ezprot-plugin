// Generic runtime helpers: sleep, cancellable process wiring, download with
// retries/timeouts, and R discovery heuristics.
import { spawnSync, type ChildProcess } from 'node:child_process'
import { createWriteStream } from 'node:fs'
import { mkdir } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { R_VERSION } from './constants.js'

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/** Kill a spawned process when the signal aborts (no-op without a signal). */
export function wireKillOnAbort(proc: ChildProcess, signal?: AbortSignal): void {
  if (!signal) return
  const onAbort = () => {
    try { proc.kill() } catch { /* already dead */ }
  }
  if (signal.aborted) {
    onAbort()
    return
  }
  signal.addEventListener('abort', onAbort)
  proc.on('close', () => signal.removeEventListener('abort', onAbort))
}

/** Download with redirects, retries, and a per-attempt timeout. Returns the destination path. */
export async function downloadFile(url: string, dest: string, opts: { retries?: number; timeoutMs?: number } = {}): Promise<string> {
  const retries = opts.retries ?? 3
  const timeoutMs = opts.timeoutMs ?? 10 * 60 * 1000
  let lastError: unknown
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const res = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(timeoutMs) })
      if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`)
      await mkdir(dirname(dest), { recursive: true })
      // Manual pump from the web stream: Node's Readable.fromWeb typing does
      // not line up with the fetch body stream across TS/DOM lib versions,
      // so bridge the reader directly instead of casting types away.
      const reader = res.body.getReader()
      const out = createWriteStream(dest)
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        if (!out.write(value)) await new Promise<void>((resolve) => out.once('drain', resolve))
      }
      out.end()
      await new Promise<void>((resolve, reject) => {
        out.on('finish', resolve)
        out.on('error', reject)
      })
      return dest
    } catch (error) {
      lastError = error
      if (attempt < retries) await sleep(2000 * attempt)
    }
  }
  throw new Error(`download failed after ${retries} attempts: ${url} (${lastError instanceof Error ? lastError.message : String(lastError)})`)
}

/** Prefer R 4.4.x; accept R >= 4.4; reject older. Returns a numeric score. */
export function versionScore(major: number, minor: number): number {
  if (major === 4 && minor === 4) return 100
  if (major === 4 && minor > 4) return 60
  if (major > 4) return 50
  return 0
}

/** PATH lookup command + binary name for the current platform. */
export function pathLookupCommand(): { cmd: string; target: string } {
  return process.platform === 'win32'
    ? { cmd: 'where', target: 'Rscript.exe' }
    : { cmd: 'which', target: 'Rscript' }
}

export interface RPathCandidate {
  path: string
  /** When true, the path is a root whose child dirs hold bin/Rscript(.exe). */
  directory: boolean
  preferred?: boolean
}

/**
 * Well-known R install locations probed by detectRscript, besides the
 * PATH lookup. Directory entries are scanned for version sub-directories
 * (R-4.4.0, R_4.4.0, ...).
 */
export function candidateScriptPaths(runtimeDir: string): RPathCandidate[] {
  const list: RPathCandidate[] = []
  if (process.platform === 'win32') {
    list.push({ path: join(runtimeDir, `R-${R_VERSION}`, 'bin', 'Rscript.exe'), directory: false, preferred: true })
    for (const root of ['D:\\R', 'C:\\Program Files\\R']) list.push({ path: root, directory: true })
  } else {
    list.push(
      { path: '/usr/local/bin/Rscript', directory: false },
      { path: '/usr/bin/Rscript', directory: false },
      { path: '/opt/homebrew/bin/Rscript', directory: false },
      { path: '/opt/R', directory: true },
    )
  }
  return list
}

/** Run `command --version`-style spawn and return the trimmed first line. */
export function spawnString(cmd: string, args: string[], timeoutMs: number): string | null {
  try {
    const res = spawnSync(cmd, args, { encoding: 'utf8', timeout: timeoutMs, windowsHide: true })
    if (res.status !== 0) return null
    return (res.stdout || '').trim()
  } catch {
    return null
  }
}
