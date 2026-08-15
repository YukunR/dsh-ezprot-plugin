// Offline snapshot restoration: extract a pre-built package-library zip into
// the managed runtime dir via PowerShell (paths travel through env vars, not
// command-string interpolation).
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync } from 'node:fs'
import type { LogSink, RuntimePaths } from './types.js'
import { wireKillOnAbort } from './util.js'

export async function restoreSnapshot(ctx: RuntimePaths, snapshotPath: string, opts: { onLog?: LogSink; timeoutMs?: number; signal?: AbortSignal } = {}): Promise<void> {
  const log: LogSink = opts.onLog ?? (() => {})
  const timeoutMs = opts.timeoutMs ?? 20 * 60 * 1000
  if (!existsSync(snapshotPath)) throw new Error(`snapshot not found: ${snapshotPath}`)
  mkdirSync(ctx.runtimeDir, { recursive: true })
  log(`Extracting offline snapshot ${snapshotPath} → ${ctx.runtimeDir}`)
  // Paths travel through environment variables, not command-string
  // interpolation, so quotes/backticks in paths cannot break out of the
  // argument; -LiteralPath also disables PowerShell wildcard expansion.
  const proc = spawn('powershell.exe', [
    '-NoProfile', '-NonInteractive', '-Command',
    'Expand-Archive -LiteralPath $env:EZPROT_SNAPSHOT_PATH -DestinationPath $env:EZPROT_DEST_DIR -Force',
  ], {
    windowsHide: true,
    env: { ...process.env, EZPROT_SNAPSHOT_PATH: snapshotPath, EZPROT_DEST_DIR: ctx.runtimeDir },
  })
  wireKillOnAbort(proc, opts.signal)
  let err = ''
  proc.stderr.on('data', (d) => { err += d; log(d) })
  const timedOut = await new Promise<boolean>((resolvePromise) => {
    const timer = setTimeout(() => {
      try { proc.kill() } catch { /* already dead */ }
      resolvePromise(true)
    }, timeoutMs)
    proc.on('error', () => { clearTimeout(timer); resolvePromise(false) })
    proc.on('close', () => { clearTimeout(timer); resolvePromise(false) })
  })
  if (timedOut) throw new Error(`snapshot extraction timed out after ${timeoutMs}ms`)
  if (!existsSync(ctx.libraryDir)) throw new Error(`snapshot extracted but no library dir found at ${ctx.libraryDir}: ${err.slice(-2000)}`)
  log('Offline snapshot restored.')
}
