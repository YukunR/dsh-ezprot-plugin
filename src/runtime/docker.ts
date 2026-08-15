// Docker backend operations: availability, local image inspection, pull with
// progress, and the in-container runtime probe.
import { spawn } from 'node:child_process'
import type { LogSink } from './types.js'
import { spawnString, wireKillOnAbort } from './util.js'

export function dockerAvailable(): boolean {
  return spawnString('docker', ['--version'], 15000) !== null
}

export function dockerImageReady(image: string): boolean {
  return spawnString('docker', ['image', 'inspect', image], 30000) !== null
}

export interface DockerRunResult {
  code: number | null
  timedOut: boolean
  tail: string
}

/**
 * Run a command inside the image: `docker run --rm <dockerArgs> <image> <cmd...>`.
 * dockerArgs must be pre-validated (mount flags etc.); cmd is argv, never shell.
 */
export async function dockerRun(image: string, dockerArgs: string[], cmd: string[], opts: { onLog?: LogSink; timeoutMs?: number; signal?: AbortSignal } = {}): Promise<DockerRunResult> {
  const log: LogSink = opts.onLog ?? (() => {})
  const timeoutMs = opts.timeoutMs ?? 30 * 60 * 1000
  const proc = spawn('docker', ['run', '--rm', ...dockerArgs, image, ...cmd], { windowsHide: true })
  wireKillOnAbort(proc, opts.signal)
  let tail = ''
  let tailFull = ''
  const push = (text: string) => {
    tailFull += text
    tail = tailFull.length > 6000 ? tailFull.slice(-6000) : tailFull
    log(text)
  }
  proc.stdout.on('data', (d: Buffer) => push(d.toString()))
  proc.stderr.on('data', (d: Buffer) => push(d.toString()))
  let timedOut = false
  const code = await new Promise<number | null>((resolvePromise) => {
    const timer = setTimeout(() => {
      timedOut = true
      try { proc.kill() } catch { /* already dead */ }
    }, timeoutMs)
    proc.on('error', () => { clearTimeout(timer); resolvePromise(null) })
    proc.on('close', (c) => { clearTimeout(timer); resolvePromise(c) })
  })
  return { code, timedOut, tail }
}

export async function dockerPull(image: string, opts: { onLog?: LogSink; timeoutMs?: number; signal?: AbortSignal } = {}): Promise<void> {
  const log: LogSink = opts.onLog ?? (() => {})
  const timeoutMs = opts.timeoutMs ?? 30 * 60 * 1000
  const proc = spawn('docker', ['pull', image], { windowsHide: true })
  wireKillOnAbort(proc, opts.signal)
  let err = ''
  proc.stdout.on('data', (d) => log(d.toString()))
  proc.stderr.on('data', (d) => { err += d.toString(); log(d.toString()) })
  let timedOut = false
  const code = await new Promise<number | null>((resolvePromise) => {
    const timer = setTimeout(() => {
      timedOut = true
      try { proc.kill() } catch { /* already dead */ }
    }, timeoutMs)
    proc.on('error', () => { clearTimeout(timer); resolvePromise(null) })
    proc.on('close', (c) => { clearTimeout(timer); resolvePromise(c) })
  })
  if (timedOut) throw new Error(`docker pull ${image} timed out after ${timeoutMs}ms`)
  if (code !== 0) throw new Error(`docker pull ${image} failed (exit ${code})\n${err.slice(-3000)}`)
}

/** Run the runtime probe INSIDE the image (the image carries check_runtime.R). */
export async function dockerVerify(image: string, opts: { onLog?: LogSink; timeoutMs?: number; signal?: AbortSignal } = {}): Promise<{ ok: boolean; failures: string[] }> {
  const log: LogSink = opts.onLog ?? (() => {})
  const timeoutMs = opts.timeoutMs ?? 20 * 60 * 1000
  const proc = spawn('docker', ['run', '--rm', image, 'Rscript', '/opt/ezprot/check_runtime.R', '/opt/ezprot/manifest-runtime.json'], { windowsHide: true })
  wireKillOnAbort(proc, opts.signal)
  let out = ''
  let err = ''
  proc.stdout.on('data', (d) => { out += d.toString(); log(d.toString()) })
  proc.stderr.on('data', (d) => { err += d.toString(); log(d.toString()) })
  let timedOut = false
  const code = await new Promise<number | null>((resolvePromise) => {
    const timer = setTimeout(() => {
      timedOut = true
      try { proc.kill() } catch { /* already dead */ }
    }, timeoutMs)
    proc.on('error', () => { clearTimeout(timer); resolvePromise(null) })
    proc.on('close', (c) => { clearTimeout(timer); resolvePromise(c) })
  })
  const failures = [...out.matchAll(/CHECK_FAIL:\s*([^\r\n]*)/g)].map((m) => m[1].trim())
  if (code !== 0 && failures.length === 0) failures.push(`probe exited with code ${code}${timedOut ? ' (timed out)' : ''}`)
  return { ok: !timedOut && code === 0 && failures.length === 0, failures }
}
