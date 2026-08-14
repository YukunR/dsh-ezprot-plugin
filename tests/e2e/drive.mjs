// End-to-end validation driver: mouse demo data through the full pipeline,
// using the local R 4.4.0 + the existing renv library.
import { rmSync, mkdirSync } from 'node:fs'
import { Runtime } from '../../lib/runtime.js'
import { Backgrounds } from '../../lib/backgrounds.js'
import { Project } from '../../lib/pipeline.js'

const RSCRIPT = 'D:\\R\\R_4.4.0\\bin\\Rscript.exe'
const RENV_LIB = 'D:\\ResearchProject\\EasyProteomicsAnalysis\\renv\\library\\windows\\R-4.4\\x86_64-w64-mingw32'
const ROOT = new URL('../..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
const projectDir = ROOT + '\\tests\\projects\\demo'

// dataDir inside the workspace so the sandboxed test run can write it
// (in the real harness the host process writes to $DSH_HOME/proteomics directly).
const runtime = new Runtime({ rscript: RSCRIPT, libraryDir: RENV_LIB, dataDir: ROOT + '\\tests\\.runtime' })
const backgrounds = new Backgrounds(runtime)

// Wipe only when EZPROT_CLEAN is set; otherwise resume from checkpoints.
if (process.env.EZPROT_CLEAN === '1') {
  rmSync(projectDir, { recursive: true, force: true })
}
mkdirSync(projectDir, { recursive: true })

console.log('[1/7] checking runtime')
console.log('rscript:', await runtime.detectRscript(), runtime.rVersion(await runtime.detectRscript()))

console.log('[2/7] ensuring mouse backgrounds')
await backgrounds.ensure('mouse', { onLog: (t) => process.stdout.write(t) })

console.log('\n[3/7] creating project')
const project = new Project(projectDir)
await project.create({
  proteinFile: ROOT + '\\tests\\fixtures\\origin_data.txt',
  sampleInfoFile: ROOT + '\\tests\\fixtures\\sample_info.txt',
  organism: 'mouse',
  organismName: 'Mus musculus',
  comparisons: [
    { control: 'NC', treatment: 'HC', name: 'HC_vs_NC' },
    { control: 'NC', treatment: 'HD', name: 'HD_vs_NC' },
  ],
  backgrounds: { go: backgrounds.goPath('mouse'), kegg: backgrounds.keggPath('mouse') },
})

const steps = ['normalization', 'pca', 'dea', 'enrich', 'gsea']
let i = 3
for (const step of steps) {
  i++
  console.log(`\n[${i}/7] ===== step: ${step} =====`)
  const started = Date.now()
  const res = await project.runStep(runtime, step, {
    onLog: (t) => process.stdout.write(t),
  })
  console.log(`\n----- ${step}: exit=${res.code} timedOut=${res.timedOut} elapsed=${((Date.now() - started) / 1000).toFixed(0)}s -----`)
  if (res.code !== 0) {
    console.log(res.tail.slice(-4000))
    process.exit(1)
  }
}

console.log('\n[7/7] ===== summaries =====')
console.log('normalization:', JSON.stringify(await project.summarizeNormalization()))
console.log('pca:', JSON.stringify(await project.summarizePca()))
console.log('dea:', JSON.stringify(await project.summarizeDea(), null, 1))
console.log('enrichment:', JSON.stringify(await project.summarizeEnrichment(), null, 1))
console.log('gsea:', JSON.stringify(await project.summarizeGsea(), null, 1))
console.log('status:', JSON.stringify(await project.status()))
console.log('\nALL STEPS PASSED')
