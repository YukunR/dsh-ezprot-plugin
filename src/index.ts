// ezprot — plug-and-play proteomics analysis bundle for DeepSeek Harness.
// TypeScript orchestration shell + R 4.4.0/Bioc 3.20 compute engine,
// auto-managed runtime (no admin/Docker required), step-wise traceable
// pipeline.
import Schema from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type { ParameterSchemaSpec, StringValueSchemaSpec } from '@deepseek-ai/dsh-tools'
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-system-prompt'
import { ProteomicsService } from './service.js'
import { buildToolDefinitions } from './tools.js'

export const name = 'ezprot'
export const inject = ['tools', 'systemPrompt']

export interface Config {
  dataDir: string
  libraryDir: string
  rscript: string
  cranRepo: string
  biocRepo: string
  enableInstall: boolean
  defaultTimeoutMs: number
  backend: string
  dockerImage: string
}

export const Config = Schema.object({
  dataDir: Schema.string().default(''),
  libraryDir: Schema.string().default(''),
  rscript: Schema.string().default(''),
  cranRepo: Schema.string().default('https://mirrors.westlake.edu.cn/CRAN'),
  biocRepo: Schema.string().default('https://mirrors.westlake.edu.cn/bioconductor'),
  enableInstall: Schema.boolean().default(true),
  defaultTimeoutMs: Schema.number().default(1800000),
  backend: Schema.string().default('auto'),
  dockerImage: Schema.string().default('ezprot:latest'),
})

const PROMPT_SECTION = [
  'Proteomics pipeline (ezprot plugin) — drive it step by step so every stage stays traceable:',
  '1. proteomics_environment action=status checks the R runtime; action=setup installs R and any missing packages automatically (one-time). The user never touches R, Docker, or a terminal.',
  '2. proteomics_preflight QCs the expression matrix + sample metadata and prepares the project. Confirm organism, groups, and comparisons with the user FIRST — never guess comparisons silently.',
  '3. Run steps in order — normalization → pca → (batch_remove only when a Batch column exists) → dea → enrich → gsea — one tool call per step, reading and narrating each summary in plain language.',
  '4. After enrich/gsea, write the biologist-facing report: overview and thresholds, top proteins with verified functions (web_search UniProt/literature — never invent), pathway story, candidate targets ranked for the research goal, suggested experiments.',
].join('\n')

export function apply(ctx: Context, config: Config) {
  const service = new ProteomicsService({
    dataDir: config.dataDir || undefined,
    libraryDir: config.libraryDir || undefined,
    rscript: config.rscript || undefined,
    cranRepo: config.cranRepo,
    biocRepo: config.biocRepo,
    enableInstall: config.enableInstall !== false,
    defaultTimeoutMs: config.defaultTimeoutMs,
    backend: config.backend,
    dockerImage: config.dockerImage,
  })
  ctx.systemPrompt.section({ name: 'ezprot', order: 120, text: PROMPT_SECTION })
  for (const def of buildToolDefinitions(service)) {
    // explicit type args: the factory types definitions as
    // DefineToolOptions<ParameterSchemaSpec, StringValueSchemaSpec>, which is
    // exactly this instantiation; inference from the broad schemas would recurse.
    ctx.tools.register(defineTool<ParameterSchemaSpec, StringValueSchemaSpec>(def))
  }
}
