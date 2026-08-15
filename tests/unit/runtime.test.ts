import { afterEach, describe, expect, it } from 'vitest'
import { createServer } from 'node:http'
import { spawnSync } from 'node:child_process'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { candidateScriptPaths, downloadFile, pathLookupCommand, Runtime } from '../../src/runtime.js'

const cleanups: Array<() => Promise<void>> = []
afterEach(async () => {
  while (cleanups.length > 0) await cleanups.pop()!()
})

async function listen(server: ReturnType<typeof createServer>): Promise<number> {
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  cleanups.push(() => new Promise<void>((resolve) => {
    server.closeAllConnections()
    server.close(() => resolve())
  }))
  return (server.address() as { port: number }).port
}

async function tempDest(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'ezprot-dl-'))
  cleanups.push(async () => { await rm(dir, { recursive: true, force: true }) })
  return join(dir, 'out.bin')
}

describe('pathLookupCommand', () => {
  it('uses where on Windows and which elsewhere', () => {
    if (process.platform === 'win32') {
      expect(pathLookupCommand()).toEqual({ cmd: 'where', target: 'Rscript.exe' })
    } else {
      expect(pathLookupCommand()).toEqual({ cmd: 'which', target: 'Rscript' })
    }
  })
})

describe('candidateScriptPaths', () => {
  it('probes Windows roots on win32', () => {
    if (process.platform !== 'win32') return
    const list = candidateScriptPaths('/x/runtime')
    expect(list.some((c) => c.path === 'D:\\R' && c.directory)).toBe(true)
    expect(list.some((c) => c.path.endsWith('R-4.4.0\\bin\\Rscript.exe') && c.preferred)).toBe(true)
  })
  it('probes POSIX locations elsewhere', () => {
    if (process.platform === 'win32') return
    const list = candidateScriptPaths('/x/runtime')
    expect(list.some((c) => c.path === '/usr/bin/Rscript')).toBe(true)
    expect(list.some((c) => c.path === '/opt/homebrew/bin/Rscript')).toBe(true)
    expect(list.some((c) => c.path === '/opt/R' && c.directory)).toBe(true)
  })
})

describe('restoreSnapshot', () => {
  it.skipIf(process.platform !== 'win32')('extracts a snapshot zip even with quotes/backticks in paths', async () => {
    // The dir name contains characters that would break naive quoting.
    const dir = await mkdtemp(join(tmpdir(), "ezprot-snap-`'q`"))
    cleanups.push(async () => { await rm(dir, { recursive: true, force: true }) })
    const lib = join(dir, 'seed', 'library')
    await mkdir(lib, { recursive: true })
    await writeFile(join(lib, 'marker.txt'), 'ok', 'utf8')
    const zip = join(dir, 'snapshot.zip')
    const res = spawnSync('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      'Compress-Archive -LiteralPath $env:EZPROT_LIB -DestinationPath $env:EZPROT_ZIP -Force',
    ], {
      encoding: 'utf8',
      env: { ...process.env, EZPROT_LIB: lib, EZPROT_ZIP: zip },
    })
    expect(res.status).toBe(0)
    const rt = new Runtime({ dataDir: join(dir, 'ds') })
    await rt.restoreSnapshot(zip)
    expect(await readFile(join(rt.libraryDir, 'marker.txt'), 'utf8')).toBe('ok')
  }, 60000)
})

describe('downloadFile', () => {
  it('downloads and writes the response body', async () => {
    const server = createServer((_req, res) => {
      res.writeHead(200, { 'content-length': '5' })
      res.end('hello')
    })
    const port = await listen(server)
    const dest = await tempDest()
    const out = await downloadFile(`http://127.0.0.1:${port}/x`, dest)
    expect(out).toBe(dest)
    expect(await readFile(dest, 'utf8')).toBe('hello')
  })

  it('fails on HTTP error status', async () => {
    const server = createServer((_req, res) => {
      res.writeHead(404)
      res.end('nope')
    })
    const port = await listen(server)
    const dest = await tempDest()
    await expect(
      downloadFile(`http://127.0.0.1:${port}/missing`, dest, { retries: 1 }),
    ).rejects.toThrow(/HTTP 404/)
  })

  it('times out when the server stalls', async () => {
    const server = createServer(() => {
      // never respond: the per-attempt timeout must fire
    })
    const port = await listen(server)
    const dest = await tempDest()
    await expect(
      downloadFile(`http://127.0.0.1:${port}/slow`, dest, { timeoutMs: 300, retries: 1 }),
    ).rejects.toThrow(/download failed after 1 attempts/)
  }, 15000)

  it('retries after a failed attempt and succeeds', async () => {
    let calls = 0
    const server = createServer((_req, res) => {
      calls++
      if (calls === 1) {
        res.writeHead(503)
        res.end()
      } else {
        res.writeHead(200)
        res.end('ok')
      }
    })
    const port = await listen(server)
    const dest = await tempDest()
    const out = await downloadFile(`http://127.0.0.1:${port}/r`, dest, { retries: 2 })
    expect(out).toBe(dest)
    expect(await readFile(dest, 'utf8')).toBe('ok')
    expect(calls).toBe(2)
  }, 15000)
})
