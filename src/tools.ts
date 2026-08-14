// Agent tool definitions for the ezprot plugin. Each tool returns plain text;
// every pipeline step is one tool call, so each stage shows up in the harness
// trajectory with its structured summary.
import type {
  DefineToolOptions,
  ParameterPropertySpec,
  ParameterSchemaSpec,
  StringValueSchemaSpec,
} from '@deepseek-ai/dsh-tools'
import { STEPS, type EnvironmentReport, type ProteomicsService } from './service.js'

type ToolDefinitionOptions = DefineToolOptions<ParameterSchemaSpec, StringValueSchemaSpec>

interface LogBuffer {
  lines: string[]
}

function logCollector(): LogBuffer & { onLog: (chunk: string) => void } {
  const lines: string[] = []
  return {
    lines,
    onLog: (chunk: string) => {
      lines.push(String(chunk))
      if (lines.length > 600) lines.splice(0, lines.length - 600)
    },
  }
}

/** Run a service promise, converting failures into readable tool errors with the log tail. */
async function guard<T>(promise: Promise<T>, log: LogBuffer): Promise<T> {
  try {
    return await promise
  } catch (error) {
    const tail = log.lines.join('').split(/\r?\n/).filter(Boolean).slice(-25).join('\n')
    const detail = tail.length > 0 ? `\n[log tail]\n${tail}` : ''
    throw new Error(`${error instanceof Error ? error.message : String(error)}${detail}`)
  }
}

const sharedParams: Record<string, ParameterPropertySpec> = {
  naThreshold: {
    type: 'array',
    items: { type: 'number' },
    description: 'NA% thresholds for auto imputation: single value, or [low, high] for c(0.6, 0.9) style KNN/Perseus/discard split. Default [0.6, 0.9].',
  },
  normalizationMethod: { type: 'string', enum: ['global', 'within_group'], description: 'Normalization method. Default "global".' },
  useCommonProteins: { type: 'boolean', description: 'Normalize using only proteins detected in all samples. Default false.' },
  imputationMethod: { type: 'string', enum: ['auto', 'knn', 'perseus'], description: 'Imputation method. Default "auto" (uses naThreshold rules).' },
  fcThresholdMode: { type: 'string', enum: ['auto', 'global', 'per_comparison'], description: 'FC threshold mode. Default "auto" (coverage analysis picks a data-driven threshold).' },
  globalFcThreshold: { type: 'number', description: 'Fold-change threshold when fcThresholdMode is "global". Default 1.5.' },
  pThresholdMode: { type: 'string', enum: ['global', 'per_comparison'], description: 'P-value threshold mode. Default "global".' },
  globalPThreshold: { type: 'number', description: 'P-value threshold when pThresholdMode is "global". Default 0.05.' },
}

const comparisonSchema: ParameterPropertySpec = {
  type: 'array',
  items: {
    type: 'object',
    additionalProperties: false,
    properties: {
      control: { oneOf: [{ type: 'string' }, { type: 'array', items: { type: 'string' } }], description: 'Control group name(s).' },
      treatment: { oneOf: [{ type: 'string' }, { type: 'array', items: { type: 'string' } }], description: 'Treatment group name(s).' },
      name: { type: 'string', description: 'Comparison name, e.g. "HD_vs_HC".' },
      fc_threshold: { type: 'number' },
      p_threshold: { type: 'number' },
    },
  },
}

const textOutput = {
  schema: { type: 'string' } as const,
  render(_args: unknown, value: unknown) {
    return [{ type: 'text' as const, text: String(value ?? '') }]
  },
}

function formatEnvironment(status: EnvironmentReport): string {
  const lines = [
    `runtime: ${status.ok ? 'ready' : 'NOT ready'} (${status.message})`,
    `Rscript: ${status.rscript ?? 'not found'} (R ${status.rVersion ?? '?'})`,
    `library: ${status.libraryDir}${status.missing && status.missing.length > 0 ? ` — missing ${status.missing.length}: ${status.missing.slice(0, 10).join(', ')}${status.missing.length > 10 ? '…' : ''}` : ''}`,
    `docker: ${status.dockerAvailable ? `available (image: ${status.dockerImage})` : 'not available'}`,
    `dataDir: ${status.dataDir}`,
  ]
  for (const [org, s] of Object.entries(status.organisms)) {
    lines.push(`${org} backgrounds: GO ${s.go ? 'ready' : s.shippedGo ? 'shipped' : 'missing'}, KEGG ${s.kegg ? 'ready' : s.shippedKegg ? 'shipped' : 'missing'}`)
  }
  if (!status.ok) lines.push('action=setup installs R and missing packages automatically (one-time, ~10-20 min); action=restore_snapshot restores an offline snapshot zip.')
  return lines.join('\n')
}

export function buildToolDefinitions(service: ProteomicsService): ToolDefinitionOptions[] {
  return [
    {
      name: 'proteomics_environment',
      description:
        'Check or set up the proteomics R runtime. action=status reports R location and missing packages; action=setup installs R 4.4.x (silent, no admin) and all missing R packages into the plugin-managed library (one-time, ~10-20 min); action=restore_snapshot extracts a pre-built offline package snapshot zip. Biologists never touch this — the plugin manages everything automatically.',
      parameters: {
        action: { type: 'string', enum: ['status', 'setup', 'restore_snapshot'], description: 'What to do. Default status.' },
        snapshotPath: { type: 'string', description: 'Path to the offline snapshot zip (only for restore_snapshot).' },
      },
      output: textOutput,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- tool args are JSON validated by defineTool
      execute: async (args: any) => {
        const log = logCollector()
        const status = await guard(service.environmentSetup({ action: (args.action as 'status' | 'setup' | 'restore_snapshot') ?? 'status', snapshotPath: args.snapshotPath, onLog: log.onLog }), log)
        return formatEnvironment(status)
      },
    },

    {
      name: 'proteomics_background',
      description:
        'Check or build the GO/KEGG annotation backgrounds for an organism (human/mouse/rat). Mouse is shipped with the plugin; human/rat are built once from KEGG REST + UniProt and cached permanently. Builds need internet once per organism; all downstream enrichment/GSEA steps use the local files and never touch the network.',
      parameters: {
        organism: { type: 'string', enum: ['human', 'mouse', 'rat'], description: 'Organism.', required: true },
        action: { type: 'string', enum: ['status', 'build'], description: 'status reports cache state; build ensures both files exist. Default status.' },
      },
      output: textOutput,
      execute: async (args: any) => {
        const log = logCollector()
        if ((args.action ?? 'status') === 'build') {
          const result = await guard(service.backgroundEnsure(args.organism as 'human' | 'mouse' | 'rat', { onLog: log.onLog }), log)
          return `backgrounds ready for ${args.organism}\nGO: ${result.go}\nKEGG: ${result.kegg}`
        }
        const status = await service.backgrounds.status(args.organism as 'human' | 'mouse' | 'rat')
        return `${args.organism}: GO ${status.go ? 'ready' : status.shippedGo ? 'available (shipped, will be copied on first use)' : 'missing'}, KEGG ${status.kegg ? 'ready' : status.shippedKegg ? 'available (shipped)' : 'missing'} — cache: ${status.cacheDir}`
      },
    },

    {
      name: 'proteomics_preflight',
      description:
        'QC and prepare a proteomics project from a protein expression matrix (tab-separated: Accession, GeneName, Description + sample columns, NaN for missing) and optional sample metadata (Sample, Group, optional Batch). Reports sample/group inference, NA pattern, duplicates, metadata mismatches; generates the project and sample_info.txt when missing. Comparisons MUST be confirmed with the user before running steps — do not guess them.',
      parameters: {
        projectDir: { type: 'string', description: 'Project directory (absolute path under the workspace).', required: true },
        proteinFile: { type: 'string', description: 'Absolute path to the protein expression matrix file.', required: true },
        sampleInfoFile: { type: 'string', description: 'Absolute path to sample metadata. If omitted, groups are inferred from sample names and a sample_info.txt is generated — review it with the user.' },
        organism: { type: 'string', enum: ['human', 'mouse', 'rat'], description: 'Organism for GO/KEGG backgrounds.', required: true },
        comparisons: { ...comparisonSchema, description: 'Confirmed comparisons, e.g. [{"control":"HC","treatment":"HD","name":"HD_vs_HC"}].' },
        params: { type: 'object', additionalProperties: false, properties: sharedParams, description: 'Optional pipeline parameter overrides (defaults are sensible).' },
      },
      output: textOutput,
      execute: async (args: any) => {
        const log = logCollector()
        return guard(
          service.preflightProject({
            projectDir: String(args.projectDir),
            proteinFile: String(args.proteinFile),
            sampleInfoFile: typeof args.sampleInfoFile === 'string' ? args.sampleInfoFile : null,
            organism: args.organism as 'human' | 'mouse' | 'rat',
            comparisons: (args.comparisons as never) ?? null,
            params: (args.params as never) ?? {},
          }),
          log,
        )
      },
    },

    {
      name: 'proteomics_step',
      description:
        `Run ONE pipeline step and return its structured summary — call it once per stage so each stage is visible in the trajectory: ${STEPS.join(', ')} (in that order; batch_remove only when the sample metadata has a Batch column). dea, enrich, gsea require completed normalization. Steps are checkpointed: a repeated call without rerun resumes instead of recomputing; rerun=true forces recomputation of that step (dea also invalidates its downstream enrich/gsea outputs).`,
      parameters: {
        projectDir: { type: 'string', description: 'Project directory (absolute path).', required: true },
        step: { type: 'string', enum: [...STEPS], description: 'Which step to run.', required: true },
        rerun: { type: 'boolean', description: 'Force recomputation of this step. Default false.' },
        params: { type: 'object', additionalProperties: false, properties: sharedParams, description: 'Parameter overrides merged into the project for this and later steps.' },
      },
      output: textOutput,
      execute: async (args: any) => {
        const log = logCollector()
        const result = await guard(service.runStep({ projectDir: String(args.projectDir), step: args.step as never, rerun: args.rerun === true, onLog: log.onLog }), log)
        return result
      },
    },

    {
      name: 'proteomics_report',
      description:
        'Return a consolidated digest of a finished proteomics project: completed steps, per-comparison DE counts, top GO/KEGG terms and GSEA sets. Use it as the skeleton for the biologist-facing report; verify protein functions and pathway biology with web_search before writing the narrative.',
      parameters: {
        projectDir: { type: 'string', description: 'Project directory (absolute path).', required: true },
      },
      output: textOutput,
      execute: async (args: any) => {
        const log = logCollector()
        return guard(service.report(String(args.projectDir)), log)
      },
    },
  ]
}
