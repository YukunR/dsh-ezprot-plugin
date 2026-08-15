// Mount smoke test: resolve the plugin exactly like the profile loader would,
// then run apply() against a mock ctx to verify Config schema, service
// construction, and tool registration end to end (no R, no child processes).
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const req = createRequire('C:/Users/Yuxiang Tang/.dsh/profiles/web/package.json')
const pluginEntry = req.resolve('dsh-ezprot-plugin')
console.log('resolved plugin entry:', pluginEntry)

const mod = await import(pathToFileURL(pluginEntry).href)
console.log('exports:', Object.keys(mod).join(', '))

const registered = []
const sections = []
const fakeCtx = {
  tools: { register: (tool) => registered.push(tool) },
  systemPrompt: { section: (s) => sections.push(s) },
  get: () => undefined,
}

const config = mod.Config({})
console.log('Config defaults:', JSON.stringify(config))

mod.apply(fakeCtx, {
  rscript: 'D:/R/R_4.4.0/bin/Rscript.exe',
  libraryDir: 'D:/ResearchProject/EasyProteomicsAnalysis/renv/library/windows/R-4.4/x86_64-w64-mingw32',
})
console.log('prompt sections:', sections.map((s) => s.name).join(', '))
console.log('tools registered:', registered.map((t) => t.name).join(', '))
for (const t of registered) {
  console.log(`  - ${t.name}: params=${Object.keys(t.parameters ?? {}).join('|')} hasExecute=${typeof t.execute === 'function'}`)
}
if (registered.length !== 8) {
  console.error('EXPECTED 8 TOOLS')
  process.exit(1)
}
console.log('MOUNT SMOKE OK')
