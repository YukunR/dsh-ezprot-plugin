// Agent tool definitions for the ezprot plugin. Every pipeline step is one
// tool call, so each stage shows up in the harness trajectory with its
// structured summary; figure-producing steps embed PNGs in the chat.
import { join } from 'node:path';
import { STEPS } from './service.js';
function logCollector() {
    const lines = [];
    return {
        lines,
        onLog: (chunk) => {
            lines.push(String(chunk));
            if (lines.length > 600)
                lines.splice(0, lines.length - 600);
        },
    };
}
/** Run a service promise, converting failures into readable tool errors with the log tail. */
async function guard(promise, log) {
    try {
        return await promise;
    }
    catch (error) {
        const tail = log.lines.join('').split(/\r?\n/).filter(Boolean).slice(-25).join('\n');
        const detail = tail.length > 0 ? `\n[log tail]\n${tail}` : '';
        throw new Error(`${error instanceof Error ? error.message : String(error)}${detail}`);
    }
}
const sharedParams = {
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
};
const comparisonSchema = {
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
};
const textOutput = {
    schema: { type: 'string' },
    render(_args, value) {
        return [{ type: 'text', text: String(value ?? '') }];
    },
};
/** Canonical value carries text + durable image refs. The MODEL-facing render
 *  is strictly text-only (the DeepSeek adapter rejects image blocks with a
 *  provider error); the image refs travel through presentationMeta, a
 *  tool-private channel a future UI can render. Humans open the PNG paths. */
const stepOutput = {
    schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
            text: { type: 'string', required: true },
            images: { type: 'array', items: { type: 'object', additionalProperties: true } },
        },
    },
    render(_args, value) {
        return [{ type: 'text', text: String(value?.text ?? '') }];
    },
    presentationMeta(_args, value) {
        // plain JSON projection of the durable image refs (tool-private channel)
        const images = (value?.images ?? []).map((im) => ({
            attachmentId: im.attachmentId,
            mediaType: im.mediaType,
            bytes: im.bytes,
            width: im.width,
            height: im.height,
            ...(im.name ? { name: im.name } : {}),
        }));
        return { images };
    },
};
function formatEnvironment(status) {
    const lines = [
        `runtime: ${status.ok ? 'ready' : 'NOT ready'} (${status.message})`,
        `Rscript: ${status.rscript ?? 'not found'} (R ${status.rVersion ?? '?'})`,
        `library: ${status.libraryDir}${status.missing && status.missing.length > 0 ? ` — missing ${status.missing.length}: ${status.missing.slice(0, 10).join(', ')}${status.missing.length > 10 ? '…' : ''}` : ''}`,
        `docker: ${status.dockerAvailable ? `available (image: ${status.dockerImage})` : 'not available'}`,
        `dataDir: ${status.dataDir}`,
    ];
    for (const [org, s] of Object.entries(status.organisms)) {
        lines.push(`${org} backgrounds: GO ${s.go ? 'ready' : s.shippedGo ? 'shipped' : 'missing'}, KEGG ${s.kegg ? 'ready' : s.shippedKegg ? 'shipped' : 'missing'}`);
    }
    if (!status.ok)
        lines.push('action=setup installs R and missing packages automatically (one-time, ~10-20 min); action=restore_snapshot restores an offline snapshot zip.');
    return lines.join('\n');
}
export function buildToolDefinitions(service, registerImage) {
    return [
        {
            name: 'proteomics_environment',
            description: 'Check or set up the proteomics R runtime. action=status reports R location and missing packages; action=setup installs R 4.4.x (silent, no admin) and all missing R packages into the plugin-managed library (one-time, ~10-20 min); action=restore_snapshot extracts a pre-built offline package snapshot zip. Biologists never touch this — the plugin manages everything automatically.',
            parameters: {
                action: { type: 'string', enum: ['status', 'setup', 'restore_snapshot'], description: 'What to do. Default status.' },
                snapshotPath: { type: 'string', description: 'Path to the offline snapshot zip (only for restore_snapshot).' },
            },
            output: textOutput,
            execute: async (args) => {
                const log = logCollector();
                const status = await guard(service.environmentSetup({ action: args.action ?? 'status', snapshotPath: args.snapshotPath, onLog: log.onLog }), log);
                return formatEnvironment(status);
            },
        },
        {
            name: 'proteomics_background',
            description: 'Check or build the GO/KEGG annotation backgrounds for an organism (human/mouse/rat). Mouse is shipped with the plugin; human/rat are built once from KEGG REST + UniProt and cached permanently. Builds need internet once per organism; all downstream enrichment/GSEA steps use the local files and never touch the network.',
            parameters: {
                organism: { type: 'string', enum: ['human', 'mouse', 'rat'], description: 'Organism.', required: true },
                action: { type: 'string', enum: ['status', 'build'], description: 'status reports cache state; build ensures both files exist. Default status.' },
            },
            output: textOutput,
            execute: async (args) => {
                const log = logCollector();
                if ((args.action ?? 'status') === 'build') {
                    const result = await guard(service.backgroundEnsure(args.organism, { onLog: log.onLog }), log);
                    return `backgrounds ready for ${args.organism}\nGO: ${result.go}\nKEGG: ${result.kegg}`;
                }
                const status = await service.backgrounds.status(args.organism);
                return `${args.organism}: GO ${status.go ? 'ready' : status.shippedGo ? 'available (shipped, will be copied on first use)' : 'missing'}, KEGG ${status.kegg ? 'ready' : status.shippedKegg ? 'available (shipped)' : 'missing'} — cache: ${status.cacheDir}`;
            },
        },
        {
            name: 'proteomics_import',
            description: 'Inspect and tidy a RAW biologist file (TSV/CSV or Excel) into the canonical matrix the pipeline expects. action=inspect parses the file, classifies columns (protein ID / gene / description / sample / droppable annotation) with heuristics, and reports a preview, missing-value counts (NaN/blank/0), sheets (Excel), and inferred sample groups. THEN ask the user which columns are the ID/gene/description, which are samples, how groups map, whether 0 means missing, and which Excel sheet. action=tidy rewrites the file into origin_data.txt + sample_info.txt per the confirmed choices. After tidy, run proteomics_preflight on the output files.',
            parameters: {
                inputFile: { type: 'string', description: 'Absolute path to the raw file (tsv/csv/xlsx/xls).', required: true },
                action: { type: 'string', enum: ['inspect', 'tidy'], description: 'Default inspect.' },
                sheet: { type: 'string', description: 'Excel sheet name (inspect lists available sheets).' },
                outputDir: { type: 'string', description: 'Directory for the tidied files (tidy only).' },
                idColumn: { type: 'string', description: 'Confirmed protein ID column (tidy only).' },
                geneColumn: { type: 'string', description: 'Confirmed gene name column (tidy only, optional).' },
                descColumn: { type: 'string', description: 'Confirmed description column (tidy only, optional).' },
                sampleColumns: { type: 'array', items: { type: 'string' }, description: 'Confirmed sample columns (tidy only).' },
                groupMapping: { type: 'object', additionalProperties: true, description: 'Optional explicit sample → group mapping; missing entries fall back to name inference (tidy only).' },
                missingZero: { type: 'boolean', description: 'Treat 0 as missing (NaN). Default true (tidy only).' },
            },
            output: textOutput,
            execute: async (args) => {
                const log = logCollector();
                if ((args.action ?? 'inspect') === 'inspect') {
                    const r = await guard(service.inspectRaw(String(args.inputFile), { sheet: args.sheet }), log);
                    const lines = [];
                    lines.push(`inspected ${r.file} — ${r.nRows} data rows, ${r.columns.length} columns`);
                    if (r.sheets.length > 0)
                        lines.push(`sheets: ${r.sheets.join(', ')}`);
                    for (const c of r.columns) {
                        lines.push(`  [${c.role}] ${c.name} — ${c.reason}${c.numericRatio !== null ? ` (${(c.numericRatio * 100).toFixed(0)}% numeric)` : ''}`);
                    }
                    lines.push(`missing values: ${r.missing.nan} NaN, ${r.missing.blank} blank, ${r.missing.zero} zeros`);
                    if (r.inferredGroups.length > 0)
                        lines.push(`inferred groups from sample-like columns: ${r.inferredGroups.join(', ')}`);
                    lines.push('preview (first 4 rows):');
                    for (const row of r.preview)
                        lines.push('  ' + row.join(' | '));
                    lines.push('NEXT: ask the user to confirm id/gene/description/sample columns, group mapping, whether 0 means missing, and the sheet — then action=tidy');
                    return lines.join('\n');
                }
                return guard(service.tidyRaw(String(args.inputFile), String(args.outputDir ?? ''), {
                    idColumn: String(args.idColumn ?? ''),
                    geneColumn: args.geneColumn,
                    descColumn: args.descColumn,
                    sampleColumns: args.sampleColumns ?? [],
                    groupMapping: args.groupMapping,
                    missingZero: args.missingZero !== false,
                    sheet: args.sheet,
                }), log);
            },
        },
        {
            name: 'proteomics_preflight',
            description: 'QC and prepare a proteomics project from a TIDIED protein expression matrix (tab-separated: Accession, GeneName, Description + sample columns, NaN for missing; use proteomics_import for raw files) and optional sample metadata (Sample, Group, optional Batch). Reports sample/group inference, NA pattern, duplicates, metadata mismatches; generates the project and sample_info.txt when missing. This tool does NOT set comparisons — after preflight, ask the user which groups to compare (ask_user_question with candidate pairs) and call proteomics_compare with the confirmed answer.',
            parameters: {
                projectDir: { type: 'string', description: 'Project directory (absolute path under the workspace).', required: true },
                proteinFile: { type: 'string', description: 'Absolute path to the protein expression matrix file.', required: true },
                sampleInfoFile: { type: 'string', description: 'Absolute path to sample metadata. If omitted, groups are inferred from sample names and a sample_info.txt is generated — review it with the user.' },
                organism: { type: 'string', enum: ['human', 'mouse', 'rat'], description: 'Organism for GO/KEGG backgrounds.', required: true },
                params: { type: 'object', additionalProperties: false, properties: sharedParams, description: 'Optional pipeline parameter overrides (defaults are sensible).' },
            },
            output: textOutput,
            execute: async (args) => {
                const log = logCollector();
                return guard(service.preflightProject({
                    projectDir: String(args.projectDir),
                    proteinFile: String(args.proteinFile),
                    sampleInfoFile: typeof args.sampleInfoFile === 'string' ? args.sampleInfoFile : null,
                    organism: args.organism,
                    params: args.params ?? {},
                }), log);
            },
        },
        {
            name: 'proteomics_compare',
            description: 'Set the project comparisons after the user has confirmed them (ask_user_question with candidate pairs first — never guess comparisons). Lightweight: updates the project state and regenerates main.R, no QC re-run. Requires a completed proteomics_preflight.',
            parameters: {
                projectDir: { type: 'string', description: 'Project directory (absolute path).', required: true },
                comparisons: { ...comparisonSchema, description: 'Confirmed comparisons, e.g. [{"control":"HC","treatment":"HD","name":"HD_vs_HC"}].', required: true },
            },
            output: textOutput,
            execute: async (args) => {
                const log = logCollector();
                return guard(service.setComparisons(String(args.projectDir), args.comparisons), log);
            },
        },
        {
            name: 'proteomics_batch',
            description: 'Manage batch assignments for a project AFTER the user has seen the PCA figures and reported batch effects. action=list shows samples/groups/current batches; action=set writes or updates the Batch column in sample_info.txt from a sample→batch mapping (the user may describe batches in natural language or point at a file — the agent converts that into the mapping); action=clear removes the Batch column. After set, run proteomics_step step=batch_remove and then step=pca rerun=true to verify the correction.',
            parameters: {
                projectDir: { type: 'string', description: 'Project directory (absolute path).', required: true },
                action: { type: 'string', enum: ['list', 'set', 'clear'], description: 'Default list.' },
                mapping: { type: 'object', additionalProperties: true, description: 'Sample → batch label mapping (action=set), e.g. {"NC_1":"1","HC_1":"2"}. Missing samples keep their current value.' },
            },
            output: textOutput,
            execute: async (args) => {
                const log = logCollector();
                const action = (args.action ?? 'list');
                if (action === 'set') {
                    return guard(service.setBatch(String(args.projectDir), (args.mapping ?? {})), log);
                }
                if (action === 'clear') {
                    return guard(service.clearBatch(String(args.projectDir)), log);
                }
                return guard(service.batchList(String(args.projectDir)), log);
            },
        },
        {
            name: 'proteomics_step',
            description: `Run ONE pipeline step and return its structured summary — call it once per stage so each stage is visible in the trajectory: ${STEPS.join(', ')} (in that order; batch_remove only after batch assignments exist, see proteomics_batch). dea, enrich, gsea require completed normalization. Steps are checkpointed: a repeated call without rerun resumes instead of recomputing; rerun=true forces recomputation of that step (dea also invalidates its downstream enrich/gsea outputs). HARD RULE: after the pca step, STOP — tell the user where the PCA figures are (the result lists PNG/PDF paths; the chat cannot embed images and read_image always fails on the text-only model), narrate the clustering from the numeric summaries, and ask (ask_user_question) whether to continue or perform batch removal before running dea.`,
            parameters: {
                projectDir: { type: 'string', description: 'Project directory (absolute path).', required: true },
                step: { type: 'string', enum: [...STEPS], description: 'Which step to run.', required: true },
                rerun: { type: 'boolean', description: 'Force recomputation of this step. Default false.' },
                params: { type: 'object', additionalProperties: false, properties: sharedParams, description: 'Parameter overrides merged into the project for this and later steps.' },
            },
            output: stepOutput,
            execute: async (args) => {
                const log = logCollector();
                const projectDir = String(args.projectDir);
                const step = args.step;
                const text = await guard(service.runStep({ projectDir, step, rerun: args.rerun === true, onLog: log.onLog }), log);
                const rels = await service.stepImages(projectDir, step);
                const images = [];
                if (registerImage) {
                    for (const rel of rels) {
                        const ref = await registerImage(join(projectDir, rel), rel);
                        if (ref)
                            images.push(ref);
                    }
                }
                const figureNote = rels.length > 0 ? `\nfigures: ${rels.join(', ')}` : '';
                return { text: text + figureNote, images };
            },
        },
        {
            name: 'proteomics_report',
            description: 'Return a consolidated digest of a finished proteomics project: completed steps, per-comparison DE counts, top GO/KEGG terms and GSEA sets. Use it as the skeleton for the biologist-facing report; verify protein functions and pathway biology with web_search before writing the narrative.',
            parameters: {
                projectDir: { type: 'string', description: 'Project directory (absolute path).', required: true },
            },
            output: textOutput,
            execute: async (args) => {
                const log = logCollector();
                return guard(service.report(String(args.projectDir)), log);
            },
        },
    ];
}
