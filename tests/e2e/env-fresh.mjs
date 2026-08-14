// Fresh-machine environment test v2: install a PRISTINE portable R 4.4.0
// (downloads the official installer and silently installs it, no admin) and
// then install the full manifest into an empty library — exactly what a new
// user's machine goes through. This machine's own R has a pre-loaded main
// library (667 packages), so any test reusing it would silently skip
// everything; the pristine R makes the install path real.
import { rmSync, existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { Runtime } from '../../lib/runtime.js'

const ROOT = new URL('../..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
const dataDir = ROOT + '\\tests\\.runtime-fresh'
const libraryDir = dataDir + '\\library'

const runtime = new Runtime({ dataDir, libraryDir })
const pristineR = await runtime.installR({ onLog: (t) => process.stdout.write(t) })
console.log(`pristine R: ${pristineR} (${runtime.rVersion(pristineR)})`)

// true isolation: wipe only on explicit request (EZPROT_FRESH=1); otherwise
// the run is incremental, like a real second launch of the installer.
if (process.env.EZPROT_FRESH === '1') {
  rmSync(libraryDir, { recursive: true, force: true })
  if (existsSync(libraryDir)) {
    console.error('FAIL: could not reset the library dir')
    process.exit(1)
  }
}

const manifest = JSON.parse(await readFile(ROOT + '\\manifest\\packages.json', 'utf8'))
console.log(`manifest: ${manifest.cran.length} CRAN + ${manifest.bioc.length} Bioc packages; library: ${libraryDir} (empty)`)
console.log(`mirrors: ${runtime.cranRepo} / ${runtime.biocRepo}`)

const started = Date.now()
await runtime.installPackages(pristineR, manifest, {
  onLog: (chunk) => process.stdout.write(chunk),
  timeoutMs: 50 * 60 * 1000,
})

const missing = await runtime.missingPackages(pristineR, manifest)
console.log(`\nelapsed: ${((Date.now() - started) / 60000).toFixed(1)} min`)
if (missing.length > 0) {
  console.error(`FAIL: still missing: ${missing.join(', ')}`)
  process.exit(1)
}
console.log('FRESH-MACHINE ENVIRONMENT TEST PASSED')
