// Runtime management: R discovery, managed R installation, package library
// installation from mirrors, offline snapshot restore, health status.
import { spawn, spawnSync, type ChildProcess } from 'node:child_process'
import { existsSync, mkdirSync, createWriteStream } from 'node:fs'
import { mkdir, readdir, readFile, rename, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Plugin package root (one level above src/). */
const packageDir = resolve(dirname(fileURLToPath(import.meta.url)), '..')
/** The installer script shipped inside the package. */
const installScriptPath = () => join(packageDir, 'r', 'install_packages.R')

export const R_VERSION = '4.4.0'
export const BIOC_VERSION = '3.20'

export const DEFAULT_MIRRORS = {
  cran: 'https://mirrors.westlake.edu.cn/CRAN',
  bioc: 'https://mirrors.westlake.edu.cn/bioconductor',
  rBase: 'https://mirrors.westlake.edu.cn/CRAN/bin/windows/base',
  fallbackCran: 'https://packagemanager.posit.co/cran/latest',
  fallbackBioc: 'https://bioconductor.org',
  fallbackRBase: 'https://cloud.r-project.org/bin/windows/base',
}

// Linux has no CRAN binary repo on the Westlake mirrors; Posit PPM serves
// pre-built Ubuntu binaries (the installer swaps in the container's codename).
// Date-pinned to the Bioc 3.20 era: PPM "latest" now targets R >= 4.5 and
// ships CRAN versions (ggplot2 4.x, ...) that Bioc 3.20 packages were never
// built against.
export const LINUX_BINARY_CRAN = 'https://packagemanager.posit.co/cran/__linux__/jammy/2024-11-15'

/** Fallback image when no dockerImage is configured or persisted. */
export const DEFAULT_DOCKER_IMAGE = 'ezprot:latest'

export interface RuntimeConfig {
  dataDir?: string
  libraryDir?: string
  rscript?: string
  cranRepo?: string
  biocRepo?: string
  enableInstall?: boolean
  defaultTimeoutMs?: number
  backend?: string
  dockerImage?: string
}

export interface PackageManifest {
  rVersion?: string
  cran: string[]
  bioc: string[]
}

export interface RuntimeStatus {
  ok: boolean
  rscript: string | null
  rVersion: string | null
  libraryDir: string
  missing: string[] | null
  message: string
}

export type LogSink = (chunk: string) => void

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
function versionScore(major: number, minor: number): number {
  if (major === 4 && minor === 4) return 100
  if (major === 4 && minor > 4) return 60
  if (major > 4) return 50
  return 0
}

export class Runtime {
  config: RuntimeConfig
  dataDir: string
  runtimeDir: string
  downloadsDir: string
  libraryDir: string
  cranRepo: string
  biocRepo: string
  rBase: string

  constructor(config: RuntimeConfig = {}) {
    this.config = config
    this.dataDir = config.dataDir || join(process.env.DSH_HOME || join(homedir(), '.dsh'), 'proteomics')
    this.runtimeDir = join(this.dataDir, 'runtime')
    this.downloadsDir = join(this.dataDir, 'downloads')
    this.libraryDir = config.libraryDir || join(this.runtimeDir, 'library')
    this.cranRepo = config.cranRepo || DEFAULT_MIRRORS.cran
    this.biocRepo = config.biocRepo || DEFAULT_MIRRORS.bioc
    this.rBase = DEFAULT_MIRRORS.rBase
  }

  /** R version string like "4.4", or null when the executable is not R. */
  rVersion(rscript: string): string | null {
    try {
      const res = spawnSync(rscript, ['--version'], { encoding: 'utf8', timeout: 20000, windowsHide: true })
      if (res.status !== 0) return null
      const m = /version\s+(\d+)\.(\d+)/.exec(res.stdout || '')
      return m ? `${m[1]}.${m[2]}` : null
    } catch {
      return null
    }
  }

  whereRscript(): string | null {
    const { cmd, target } = pathLookupCommand()
    try {
      const res = spawnSync(cmd, [target], { encoding: 'utf8', timeout: 15000, windowsHide: true })
      const first = (res.stdout || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean)[0]
      return first || null
    } catch {
      return null
    }
  }

  /** Locate a usable Rscript (config override → plugin-managed → common dirs → PATH). */
  async detectRscript(): Promise<string | null> {
    if (this.config.rscript) return this.config.rscript
    const exe = process.platform === 'win32' ? 'Rscript.exe' : 'Rscript'
    const candidates: Array<{ path: string; preferred: boolean }> = []
    for (const c of candidateScriptPaths(this.runtimeDir)) {
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
      const v = this.rVersion(c.path)
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
    const onPath = this.whereRscript()
    if (onPath) {
      const v = this.rVersion(onPath)
      if (v) {
        const [major, minor] = v.split('.').map(Number)
        if (versionScore(major, minor) > 0) return onPath
      }
    }
    return null
  }

  /** Download and silently install the pinned R version into the managed dir (no admin). */
  async installR(opts: { onLog?: LogSink; signal?: AbortSignal } = {}): Promise<string> {
    const log: LogSink = opts.onLog ?? (() => {})
    const installer = join(this.downloadsDir, `R-${R_VERSION}-win.exe`)
    const installDir = join(this.runtimeDir, `R-${R_VERSION}`)
    if (existsSync(join(installDir, 'bin', 'Rscript.exe'))) {
      log(`R ${R_VERSION} already installed at ${installDir}`)
      return join(installDir, 'bin', 'Rscript.exe')
    }
    mkdirSync(this.downloadsDir, { recursive: true })
    const urls = [
      `${this.rBase}/old/${R_VERSION}/R-${R_VERSION}-win.exe`,
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

  /** Names of packages currently installed in the managed library. */
  installedPackages(rscript: string): Promise<string[]> {
    return new Promise((resolvePromise, reject) => {
      let out = ''
      let err = ''
      const proc = spawn(rscript, ['-e', 'cat(paste(rownames(installed.packages()), collapse="\\n"))'], {
        env: { ...process.env, R_LIBS_USER: this.libraryDir },
        windowsHide: true,
      })
      proc.stdout.on('data', (d) => (out += d))
      proc.stderr.on('data', (d) => (err += d))
      proc.on('error', reject)
      proc.on('close', (code) => {
        if (code !== 0) reject(new Error(`installed.packages() failed (exit ${code}): ${err.slice(0, 2000)}`))
        else resolvePromise(out.split(/\r?\n/).map((s) => s.trim()).filter(Boolean))
      })
    })
  }

  /** Install every manifest package that is missing from the managed library. */
  async installPackages(rscript: string, manifest: PackageManifest, opts: { onLog?: LogSink; timeoutMs?: number; signal?: AbortSignal } = {}): Promise<void> {
    const log: LogSink = opts.onLog ?? (() => {})
    const timeoutMs = opts.timeoutMs ?? 45 * 60 * 1000
    mkdirSync(this.libraryDir, { recursive: true })
    const runtimeManifest = {
      cran: manifest.cran,
      bioc: manifest.bioc,
      biocVersion: BIOC_VERSION,
      repos: { cran: this.cranRepo, bioc: this.biocRepo, linuxBinaryCran: LINUX_BINARY_CRAN },
    }
    await writeFile(join(this.dataDir, 'manifest-runtime.json'), JSON.stringify(runtimeManifest))
    // NOTE: Rscript takes the script path as a plain positional argument;
    // `--file=` is an R (CMD BATCH) flag that Rscript does NOT interpret as
    // the script selector, so passing it here made Rscript parse the JSON
    // manifest as the script (caught by the fresh-machine test).
    const proc = spawn(rscript, [installScriptPath(), join(this.dataDir, 'manifest-runtime.json')], {
      cwd: this.dataDir,
      env: { ...process.env, R_LIBS_USER: this.libraryDir },
      windowsHide: true,
    })
    wireKillOnAbort(proc, opts.signal)
    let out = ''
    let err = ''
    proc.stdout.on('data', (d) => { out += d; log(d) })
    proc.stderr.on('data', (d) => { err += d; log(d) })
    const timedOut = await new Promise<boolean>((resolvePromise) => {
      const timer = setTimeout(() => {
        try { proc.kill() } catch { /* already dead */ }
        resolvePromise(true)
      }, timeoutMs)
      proc.on('error', () => { clearTimeout(timer); resolvePromise(false) })
      proc.on('close', () => { clearTimeout(timer); resolvePromise(false) })
    })
    const stillMissingMatch = /STILL_MISSING:[^\r\n]*/.exec(out)
    if (timedOut) throw new Error(`package installation timed out after ${timeoutMs}ms`)
    if (stillMissingMatch) {
      const listed = stillMissingMatch[0].replace(/^STILL_MISSING:\s*/, '').trim()
      if (listed !== '') {
        throw new Error(`these packages are still missing after installation: ${listed}\n${err.slice(-4000)}`)
      }
    }
    const allOk = /ALL_PACKAGES_OK/.test(out)
    if (!allOk) throw new Error(`package installation did not finish successfully\n${(err || out).slice(-4000)}`)
    log('All required R packages are installed.')
  }

  /** Missing manifest packages (empty = complete library). */
  async missingPackages(rscript: string, manifest: PackageManifest): Promise<string[]> {
    const installed = await this.installedPackages(rscript)
    const required = [...(manifest.cran ?? []), ...(manifest.bioc ?? [])]
    return required.filter((pkg) => !installed.includes(pkg))
  }

  /**
   * Runtime capability probe: loads every manifest package and exercises the
   * heavy pipeline code paths (PCAtools encircle/ggalt, ComBat, enricher).
   * Catches Suggests-only gaps that static manifest checks cannot see.
   */
  async verifyRuntime(rscript: string, manifest: PackageManifest, opts: { onLog?: LogSink; timeoutMs?: number; signal?: AbortSignal } = {}): Promise<{ ok: boolean; failures: string[]; tail: string }> {
    const log: LogSink = opts.onLog ?? (() => {})
    const timeoutMs = opts.timeoutMs ?? 15 * 60 * 1000
    const runtimeManifest = {
      cran: manifest.cran,
      bioc: manifest.bioc,
      biocVersion: BIOC_VERSION,
      repos: { cran: this.cranRepo, bioc: this.biocRepo, linuxBinaryCran: LINUX_BINARY_CRAN },
    }
    await writeFile(join(this.dataDir, 'manifest-runtime.json'), JSON.stringify(runtimeManifest))
    const proc = spawn(rscript, [join(packageDir, 'r', 'check_runtime.R'), join(this.dataDir, 'manifest-runtime.json')], {
      cwd: this.dataDir,
      env: { ...process.env, R_LIBS_USER: this.libraryDir },
      windowsHide: true,
    })
    wireKillOnAbort(proc, opts.signal)
    let out = ''
    let err = ''
    proc.stdout.on('data', (d) => { out += d; log(d) })
    proc.stderr.on('data', (d) => { err += d; log(d) })
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
    if (code !== 0 && failures.length === 0) {
      failures.push(`probe exited with code ${code}`)
    }
    return {
      ok: !timedOut && code === 0 && failures.length === 0,
      failures,
      tail: (err || out).slice(-3000),
    }
  }

  // ── runtime state + Docker backend ────────────────────────────────────────
  /** Persisted backend choice (written by environment setup, read by steps). */
  statePath(): string {
    return join(this.dataDir, 'runtime-state.json')
  }

  async getState(): Promise<{ backend?: 'local' | 'docker'; dockerImage?: string }> {
    try {
      const raw = await readFile(this.statePath(), 'utf8')
      const parsed = JSON.parse(raw) as { backend?: string; dockerImage?: string }
      return {
        backend: parsed.backend === 'docker' || parsed.backend === 'local' ? parsed.backend : undefined,
        dockerImage: typeof parsed.dockerImage === 'string' ? parsed.dockerImage : undefined,
      }
    } catch {
      return {}
    }
  }

  // Serializes state updates: each setState re-reads the file after the
  // previous write completes, so concurrent callers cannot lose fields.
  private stateQueue: Promise<unknown> = Promise.resolve()

  async setState(patch: { backend?: 'local' | 'docker'; dockerImage?: string }): Promise<void> {
    const run = this.stateQueue.then(async () => {
      await mkdir(this.dataDir, { recursive: true })
      const current = await this.getState()
      // write-then-rename: readers (getState) never observe a torn file
      const tmp = `${this.statePath()}.tmp`
      await writeFile(tmp, JSON.stringify({ ...current, ...patch }, null, 2), 'utf8')
      await rename(tmp, this.statePath())
    })
    this.stateQueue = run.catch(() => {})
    await run
  }

  dockerAvailable(): boolean {
    try {
      const res = spawnSync('docker', ['--version'], { encoding: 'utf8', timeout: 15000, windowsHide: true })
      return res.status === 0
    } catch {
      return false
    }
  }

  async dockerImageReady(image: string): Promise<boolean> {
    try {
      const res = spawnSync('docker', ['image', 'inspect', image], { encoding: 'utf8', timeout: 30000, windowsHide: true })
      return res.status === 0
    } catch {
      return false
    }
  }

  async dockerPull(image: string, opts: { onLog?: LogSink; timeoutMs?: number; signal?: AbortSignal } = {}): Promise<void> {
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
  async dockerVerify(image: string, opts: { onLog?: LogSink; timeoutMs?: number; signal?: AbortSignal } = {}): Promise<{ ok: boolean; failures: string[] }> {
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

  /** Extract a previously created offline snapshot zip into the managed runtime dir. */
  async restoreSnapshot(snapshotPath: string, opts: { onLog?: LogSink; timeoutMs?: number; signal?: AbortSignal } = {}): Promise<void> {
    const log: LogSink = opts.onLog ?? (() => {})
    const timeoutMs = opts.timeoutMs ?? 20 * 60 * 1000
    if (!existsSync(snapshotPath)) throw new Error(`snapshot not found: ${snapshotPath}`)
    mkdirSync(this.runtimeDir, { recursive: true })
    log(`Extracting offline snapshot ${snapshotPath} → ${this.runtimeDir}`)
    // Paths travel through environment variables, not command-string
    // interpolation, so quotes/backticks in paths cannot break out of the
    // argument; -LiteralPath also disables PowerShell wildcard expansion.
    const proc = spawn('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      'Expand-Archive -LiteralPath $env:EZPROT_SNAPSHOT_PATH -DestinationPath $env:EZPROT_DEST_DIR -Force',
    ], {
      windowsHide: true,
      env: { ...process.env, EZPROT_SNAPSHOT_PATH: snapshotPath, EZPROT_DEST_DIR: this.runtimeDir },
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
    if (!existsSync(this.libraryDir)) throw new Error(`snapshot extracted but no library dir found at ${this.libraryDir}: ${err.slice(-2000)}`)
    log('Offline snapshot restored.')
  }

  /** Full environment health report. */
  async status(manifest?: PackageManifest): Promise<RuntimeStatus> {
    const rscript = await this.detectRscript()
    if (!rscript) {
      return { ok: false, rscript: null, rVersion: null, libraryDir: this.libraryDir, missing: [], message: 'no R installation found (run environment setup)' }
    }
    const rVersion = this.rVersion(rscript)
    let missing: string[] | null = []
    try {
      missing = await this.missingPackages(rscript, manifest ?? { cran: [], bioc: [] })
    } catch {
      missing = null // library probe failed
    }
    return {
      ok: rVersion !== null && missing !== null && missing.length === 0,
      rscript,
      rVersion,
      libraryDir: this.libraryDir,
      missing,
      message: missing === null
        ? 'package library could not be probed'
        : missing.length === 0
          ? 'runtime ready'
          : `${missing.length} package(s) missing`,
    }
  }
}

