// Re-run only the GSEA step (with the plot cap) and verify the JS
// summary parsers for enrichment and GSEA outputs.
import { rmSync, cpSync } from 'node:fs'
import { Runtime } from '../../lib/runtime.js'
import { Backgrounds } from '../../lib/backgrounds.js'
import { Project } from '../../lib/pipeline.js'

const RSCRIPT = 'D:\\R\\R_4.4.0\\bin\\Rscript.exe'
const RENV_LIB = 'D:\\ResearchProject\\EasyProteomicsAnalysis\\renv\\library\\windows\\R-4.4\\x86_64-w64-mingw32'
const ROOT = new URL('../..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
const projectDir = ROOT + '\\tests\\projects\\demo'

// re-sync the pipeline scripts into the existing project (source changed since create)
cpSync(ROOT + '\\r\\analysis_steps.R', `${projectDir}\\analysis_steps.R`)
cpSync(ROOT + '\\r\\run.R', `${projectDir}\\run.R`)
cpSync(ROOT + '\\r\\core', `${projectDir}\\core`, { recursive: true })
cpSync(ROOT + '\\r\\utils', `${projectDir}\\utils`, { recursive: true })

const runtime = new Runtime({ rscript: RSCRIPT, libraryDir: RENV_LIB, dataDir: ROOT + '\\tests\\.runtime' })
const project = new Project(projectDir)

for (const comp of ['HC_vs_NC', 'HD_vs_NC']) {
  rmSync(`${projectDir}\\res\\dea_results\\${comp}\\gsea_results`, { recursive: true, force: true })
}

console.log('===== re-running gsea (capped plots) =====')
const res = await project.runStep(runtime, 'gsea', {
  onLog: (t) => process.stdout.write(t),
})
console.log(`\n----- gsea: exit=${res.code} timedOut=${res.timedOut} -----`)
if (res.code !== 0) {
  console.log(res.tail.slice(-4000))
  process.exit(1)
}

console.log('===== enrichment summary =====')
console.log(JSON.stringify(await project.summarizeEnrichment(), null, 1))
console.log('===== gsea summary =====')
console.log(JSON.stringify(await project.summarizeGsea(), null, 1))
console.log('===== status =====')
console.log(JSON.stringify(await project.status()))
console.log('SUMMARY CHECK OK')
