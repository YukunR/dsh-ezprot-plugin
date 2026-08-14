// ezprot — plug-and-play proteomics analysis bundle for DeepSeek Harness.
// TypeScript orchestration shell + R 4.4.0/Bioc 3.20 compute engine,
// auto-managed runtime (no admin/Docker required), step-wise traceable
// pipeline.
import { readFile } from 'node:fs/promises'
import Schema from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type { ParameterSchemaSpec } from '@deepseek-ai/dsh-tools'
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-system-prompt'
import type {} from '@deepseek-ai/dsh-attachment'
import { ProteomicsService } from './service.js'
import { buildToolDefinitions, type ImageRefLike } from './tools.js'

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
  'Proteomics pipeline (ezprot plugin) — drive it step by step so every stage stays traceable. The user is usually a biologist: they never touch R, Docker, or a terminal.',
  '1. Raw files: when the user provides a raw TSV/CSV/Excel matrix, run proteomics_import action=inspect first, then ASK the user (ask_user_question) to confirm which columns are protein ID / gene / description / samples, how groups map, whether 0 means missing, and the Excel sheet; only then action=tidy. If the file is already the canonical matrix (Accession, GeneName, Description + samples), skip the import step.',
  '2. proteomics_environment action=status checks the R runtime; action=setup installs R and any missing packages automatically (one-time).',
  '3. proteomics_preflight QCs the tidied matrix + sample metadata and prepares the project. It does NOT set comparisons.',
  '4. HARD RULE — comparisons: after preflight, ASK the user which groups to compare (ask_user_question offering candidate pairs from the inferred groups); never guess. Only after the user confirms, call proteomics_compare with exactly those comparisons.',
  '5. Steps in order — normalization → pca → (batch_remove only after the user confirmed batch correction) → dea → enrich → gsea — one tool call per step, reading and narrating each summary in plain language.',
  '6. HARD RULE — PCA gate: after the pca step, STOP. Tell the user where the PCA figures are (the result text lists the PNG/PDF paths — this chat cannot embed images), narrate the clustering in plain language, and ask (ask_user_question) whether to continue or perform batch removal. Do not run dea before the user answers.',
  '7. Batch injection: batch structure is usually only known AFTER seeing the PCA. When the user reports batch effects, ask them to describe which samples belong to which batch (natural language or a file); record it with proteomics_batch action=set, then run batch_remove and pca rerun=true to verify the correction before continuing.',
  '8. After enrich/gsea, write the biologist-facing report: overview and thresholds, top proteins with verified functions (web_search UniProt/literature — never invent), pathway story, candidate targets ranked for the research goal, suggested experiments.',
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
  const attachments = ctx.get('attachments')
  const registerImage = attachments === undefined
    ? undefined
    : async (absPath: string, name?: string): Promise<ImageRefLike | null> => {
        try {
          const data = await readFile(absPath)
          const ref = await attachments.saveImage({ data, mediaType: 'image/png', name })
          return {
            attachmentId: ref.attachmentId,
            mediaType: ref.mediaType,
            bytes: ref.bytes,
            width: ref.width,
            height: ref.height,
            ...(ref.name ? { name: ref.name } : {}),
          }
        } catch {
          return null
        }
      }
  ctx.systemPrompt.section({ name: 'ezprot', order: 120, text: PROMPT_SECTION })
  for (const def of buildToolDefinitions(service, registerImage)) {
    ctx.tools.register(defineTool<ParameterSchemaSpec, any>(def))
  }
}
