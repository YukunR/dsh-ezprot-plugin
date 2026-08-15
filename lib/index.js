// ezprot — plug-and-play proteomics analysis bundle for DeepSeek Harness.
// TypeScript orchestration shell + R 4.4.0/Bioc 3.20 compute engine,
// auto-managed runtime (no admin/Docker required), step-wise traceable
// pipeline.
import { readFile, stat } from 'node:fs/promises';
import Schema from '@deepseek-ai/schemastery';
import { defineTool } from '@deepseek-ai/dsh-tools';
import { ProteomicsService } from './service.js';
import { buildToolDefinitions } from './tools.js';
export const name = 'ezprot';
export const inject = ['tools', 'systemPrompt'];
export const Config = Schema.object({
    dataDir: Schema.string().default(''),
    libraryDir: Schema.string().default(''),
    rscript: Schema.string().default(''),
    cranRepo: Schema.string().default('https://mirrors.westlake.edu.cn/CRAN'),
    biocRepo: Schema.string().default('https://mirrors.westlake.edu.cn/bioconductor'),
    enableInstall: Schema.boolean().default(true),
    defaultTimeoutMs: Schema.number().default(1800000),
    backend: Schema.string().default('auto'),
    dockerImage: Schema.string().default('yukunru/ezprot:latest'),
});
const PROMPT_SECTION = [
    'Proteomics pipeline (ezprot plugin) — drive it step by step so every stage stays traceable. The user is usually a biologist: they never touch R, Docker, or a terminal.',
    '1. Raw files: when the user provides a raw TSV/CSV/Excel matrix, run proteomics_import action=inspect first, then ASK the user (ask_user_question) to confirm which columns are protein ID / gene / description / samples, how groups map, whether 0 means missing, and the Excel sheet; only then action=tidy. If the file is already the canonical matrix (Accession, GeneName, Description + samples), skip the import step.',
    '2. proteomics_environment action=status checks the R runtime (and reports whether Docker is available). When the environment is NOT ready, ASK the user which installation path they prefer (ask_user_question), listing the trade-offs: Docker image — stable/reproducible, zero system pollution, pulls once (a few minutes); requires Docker installed. Local R — no prerequisites, fully automatic (one-time 10-20 min, downloads from package mirrors; offline snapshot possible). Then run action=setup with the backend the user chose (backend=docker or backend=local). setup runs as a BACKGROUND JOB: it returns a jobId — poll job_output(jobId) repeatedly and narrate progress to the user in plain language (packages downloading / installing, or image pulling), then finish with action=status (and action=verify after a first-time local setup).',
    '3. proteomics_preflight QCs the tidied matrix + sample metadata and prepares the project. It does NOT set comparisons.',
    '4. HARD RULE — comparisons: after preflight, ASK the user which groups to compare (ask_user_question offering candidate pairs from the inferred groups); never guess. Only after the user confirms, call proteomics_compare with exactly those comparisons.',
    '5. Steps in order — normalization → pca → (batch_remove only after the user confirmed batch correction) → dea → enrich → gsea — one tool call per step, reading and narrating each summary in plain language.',
    '6. HARD RULE — PCA gate: after the pca step, STOP. Tell the user where the PCA figures are (the result text lists the PNG/PDF paths — this chat cannot embed images), narrate the clustering from the numeric summaries in plain language, and ask (ask_user_question) whether to continue or perform batch removal. Do not run dea before the user answers.',
    '7. Viewing figures: you MAY call read_image on the PNG figures to inspect them visually when the model supports image input. If read_image fails (text-only model), do not retry — fall back to describing the figure from the numeric/statistical summaries and ask the user to open the PNG/PDF files (this chat cannot embed images).',
    '8. Batch injection: batch structure is usually only known AFTER seeing the PCA. When the user reports batch effects, ask them to describe which samples belong to which batch (natural language or a file); record it with proteomics_batch action=set, then run batch_remove and pca rerun=true to verify the correction before continuing.',
    '9. After enrich/gsea, write the biologist-facing report: overview and thresholds, top proteins with verified functions (web_search UniProt/literature — never invent), pathway story, candidate targets ranked for the research goal, suggested experiments.',
    '10. Network-restricted sandboxes: when a network step (environment setup, background build) fails with TLS/certificate errors or repeated timeouts while Docker-backed steps still work, the HOST process is sandboxed without network access. Ask the user (ask_user_question) whether to retry with elevated permissions or switch that step to the Docker backend (containers are not affected by the host sandbox; the plugin builds annotation backgrounds inside the image when the Docker backend is selected). Never retry the same restricted call more than twice without asking.',
].join('\n');
export function apply(ctx, config) {
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
    });
    // Lazy lookup: the plugin does not declare an 'attachments' dependency, so
    // the service may mount after apply() runs. Resolving it inside the call
    // (rather than once at apply time) is what makes registration reliable.
    const registerImage = async (absPath, name) => {
        try {
            const attachments = ctx.get('attachments');
            if (attachments === undefined)
                return null;
            // Cap at 20 MB: high-DPI heatmaps can be large, and the attachment
            // service is not a file archive — humans open the PNG paths anyway.
            const info = await stat(absPath);
            if (info.size > 20 * 1024 * 1024)
                return null;
            const data = await readFile(absPath);
            const ref = await attachments.saveImage({ data, mediaType: 'image/png', name });
            return {
                attachmentId: ref.attachmentId,
                mediaType: ref.mediaType,
                bytes: ref.bytes,
                width: ref.width,
                height: ref.height,
                ...(ref.name ? { name: ref.name } : {}),
            };
        }
        catch {
            return null;
        }
    };
    // Lazy lookup: the jobs registry (like attachments) may mount after apply().
    const getJobs = () => ctx.get('jobs') ?? undefined;
    ctx.systemPrompt.section({ name: 'ezprot', order: 120, text: PROMPT_SECTION });
    for (const def of buildToolDefinitions(service, registerImage, getJobs)) {
        ctx.tools.register(defineTool(def));
    }
}
