// Pipeline execution: project workspace creation, main.R generation from the
// template, non-interactive R step runner, CSV result parsing into structured
// step summaries (these summaries are what lands in the harness trajectory).
import { spawn } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { copyFile, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DEFAULT_DOCKER_IMAGE } from './runtime.js';
import { looksNumeric } from './import.js';
export const packageDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const rDir = join(packageDir, 'r');
// ── R literal builders ──────────────────────────────────────────────────────
/** Escape content for an ALREADY-QUOTED template placeholder (no quotes added). */
export function rEscape(value) {
    // split/join (NOT String.replace) so every backslash becomes two
    return String(value).split('\\').join('\\\\').split('"').join('\\"');
}
/** Full R string literal, including the surrounding quotes. */
export function rString(value) {
    return `"${rEscape(value)}"`;
}
export function rLogical(value) {
    return value ? 'TRUE' : 'FALSE';
}
export function rNumber(value) {
    return Number.isFinite(Number(value)) ? String(Number(value)) : String(value);
}
export function rVector(values) {
    return `c(${values.map(rString).join(', ')})`;
}
export function rNaThreshold(value) {
    if (value === undefined || value === null)
        return 'c(0.6, 0.9)';
    if (Array.isArray(value))
        return `c(${value.map(rNumber).join(', ')})`;
    return rNumber(value);
}
export function rComparisons(comparisons) {
    const parts = (comparisons ?? []).map((comp) => {
        const entries = [];
        const control = Array.isArray(comp.control) ? rVector(comp.control) : rString(comp.control);
        const treatment = Array.isArray(comp.treatment) ? rVector(comp.treatment) : rString(comp.treatment);
        entries.push(`control = ${control}`);
        entries.push(`treatment = ${treatment}`);
        entries.push(`name = ${rString(comp.name)}`);
        if (comp.fc_threshold !== undefined)
            entries.push(`fc_threshold = ${rNumber(comp.fc_threshold)}`);
        if (comp.p_threshold !== undefined)
            entries.push(`p_threshold = ${rNumber(comp.p_threshold)}`);
        return `list(${entries.join(', ')})`;
    });
    return `list(${parts.join(', ')})`;
}
export function parseCsv(text) {
    const rows = [];
    let row = [];
    let field = '';
    let inQuotes = false;
    for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        if (inQuotes) {
            if (ch === '"') {
                if (text[i + 1] === '"') {
                    field += '"';
                    i++;
                }
                else {
                    inQuotes = false;
                }
            }
            else {
                field += ch;
            }
        }
        else if (ch === '"') {
            inQuotes = true;
        }
        else if (ch === ',') {
            row.push(field);
            field = '';
        }
        else if (ch === '\n' || ch === '\r') {
            if (ch === '\r' && text[i + 1] === '\n')
                i++;
            row.push(field);
            if (row.length > 1 || row[0] !== '')
                rows.push(row);
            row = [];
            field = '';
        }
        else {
            field += ch;
        }
    }
    row.push(field);
    if (row.length > 1 || row[0] !== '')
        rows.push(row);
    if (rows.length === 0)
        return [];
    const header = rows[0];
    return rows.slice(1).map((cells) => {
        const obj = {};
        header.forEach((h, idx) => {
            obj[h] = cells[idx] ?? '';
        });
        return obj;
    });
}
async function readCsvIfExists(path) {
    if (!existsSync(path))
        return [];
    try {
        return parseCsv(await readFile(path, 'utf8'));
    }
    catch {
        return [];
    }
}
async function listDirs(base) {
    try {
        const entries = await readdir(base, { withFileTypes: true });
        return entries.filter((e) => e.isDirectory()).map((e) => e.name);
    }
    catch {
        return [];
    }
}
export class Project {
    dir;
    constructor(projectDir) {
        this.dir = resolve(projectDir);
    }
    static defaultPath(name, workspaceRoot) {
        return join(workspaceRoot || process.cwd(), 'proteomics', name);
    }
    statePath() {
        return join(this.dir, '.ezprot.json');
    }
    loadState() {
        try {
            return JSON.parse(readFileSync(this.statePath(), 'utf8'));
        }
        catch {
            return null;
        }
    }
    saveState(state) {
        mkdirSync(this.dir, { recursive: true });
        writeFileSync(this.statePath(), JSON.stringify(state, null, 2), 'utf8');
        return state;
    }
    /** Create the project: copy inputs, copy pipeline scripts, generate main.R. */
    async create(opts) {
        const { proteinFile, sampleInfoFile = null, organism, organismName, comparisons, params = {}, backgrounds = {} } = opts;
        mkdirSync(join(this.dir, 'data'), { recursive: true });
        // inputs — copy only when the source is outside the destination path:
        // copying a file onto itself is platform-dependent (EINVAL on Linux) and
        // re-running preflight on an existing project passes the project's own
        // files back in.
        const originDest = join(this.dir, 'data', 'origin_data.txt');
        if (resolve(proteinFile) !== resolve(originDest)) {
            await copyFile(proteinFile, originDest);
        }
        if (sampleInfoFile) {
            const dest = join(this.dir, 'data', 'sample_info.txt');
            if (resolve(sampleInfoFile) !== resolve(dest)) {
                await copyFile(sampleInfoFile, dest);
            }
        }
        // pipeline scripts
        cpSync(join(rDir, 'analysis_steps.R'), join(this.dir, 'analysis_steps.R'));
        cpSync(join(rDir, 'run.R'), join(this.dir, 'run.R'));
        cpSync(join(rDir, 'core'), join(this.dir, 'core'), { recursive: true });
        cpSync(join(rDir, 'utils'), join(this.dir, 'utils'), { recursive: true });
        const state = this.saveState({
            created: new Date().toISOString(),
            organism,
            organismName,
            comparisons,
            params,
            backgrounds,
        });
        this.regenerateMainR(state);
        return state;
    }
    /** Regenerate main.R from the current state (idempotent; safe to re-run). */
    regenerateMainR(state) {
        const template = readFileSync(join(rDir, 'main_template.R'), 'utf8');
        const subs = {
            '{{ORGANISM}}': rEscape(state.organismName ?? state.organism ?? ''),
            '{{DATE}}': new Date().toISOString().slice(0, 10),
            '{{PROTEIN_EXPR_FILE}}': rEscape('data/origin_data.txt'),
            '{{SAMPLE_INFO_FILE}}': rEscape('data/sample_info.txt'),
            '{{OUTPUT_DIR}}': rEscape('res/'),
            '{{GO_BACKGROUND_FILE}}': rEscape(state.backgrounds?.go ?? ''),
            '{{KEGG_BACKGROUND_FILE}}': rEscape(state.backgrounds?.kegg ?? ''),
            '{{NA_THRESHOLD}}': rNaThreshold(state.params?.naThreshold),
            '{{NORMALIZATION_METHOD}}': rEscape(state.params?.normalizationMethod ?? 'global'),
            '{{USE_COMMON_PROTEINS}}': rLogical(state.params?.useCommonProteins ?? false),
            '{{IMPUTATION_METHOD}}': rEscape(state.params?.imputationMethod ?? 'auto'),
            '{{FC_THRESHOLD_MODE}}': rEscape(state.params?.fcThresholdMode ?? 'auto'),
            '{{GLOBAL_FC_THRESHOLD}}': rNumber(state.params?.globalFcThreshold ?? 1.5),
            '{{P_THRESHOLD_MODE}}': rEscape(state.params?.pThresholdMode ?? 'global'),
            '{{GLOBAL_P_THRESHOLD}}': rNumber(state.params?.globalPThreshold ?? 0.05),
            '{{COMPARISONS_LIST}}': rComparisons(state.comparisons),
        };
        let mainR = template;
        for (const [key, value] of Object.entries(subs)) {
            mainR = mainR.split(key).join(value);
        }
        writeFileSync(join(this.dir, 'main.R'), mainR, 'utf8');
        return mainR;
    }
    /**
     * Run one pipeline step non-interactively. Streams R output to onLog.
     * backend 'docker' runs the project's own run.R inside a container that
     * mounts this project directory at /workspace (see docker/Dockerfile);
     * the default 'local' backend uses the managed Rscript.
     */
    async runStep(runtime, step, opts = {}) {
        const log = opts.onLog ?? (() => { });
        const timeoutMs = opts.timeoutMs ?? 30 * 60 * 1000;
        const stepArgs = [step];
        if (opts.rerun)
            stepArgs.push('--rerun', step);
        let proc;
        if (opts.backend === 'docker') {
            // Docker Desktop accepts native Windows paths in -v; the container
            // runs the project's own run.R (scripts were copied at preflight).
            // The annotation background cache is mounted at its host path so the
            // absolute paths baked into main.R resolve identically in-container.
            const toHostPath = (p) => p.replace(/\\/g, '/');
            mkdirSync(join(runtime.dataDir, 'backgrounds'), { recursive: true });
            proc = spawn('docker', [
                'run', '--rm',
                '-w', '/workspace',
                '-v', `${this.dir}:/workspace`,
                '-v', `${toHostPath(join(runtime.dataDir, 'backgrounds'))}:${toHostPath(join(runtime.dataDir, 'backgrounds'))}`,
                opts.dockerImage ?? DEFAULT_DOCKER_IMAGE,
                '/workspace/run.R', ...stepArgs,
            ], { windowsHide: true });
        }
        else {
            const rscript = await runtime.detectRscript();
            if (!rscript)
                throw new Error('no R installation found; run proteomics_environment with action=setup first');
            mkdirSync(runtime.libraryDir, { recursive: true });
            proc = spawn(rscript, ['run.R', ...stepArgs], {
                cwd: this.dir,
                env: { ...process.env, R_LIBS_USER: runtime.libraryDir },
                windowsHide: true,
            });
        }
        let tail = '';
        let tailFull = '';
        const push = (text) => {
            tailFull += text;
            tail = tailFull.length > 6000 ? tailFull.slice(-6000) : tailFull;
            log(text);
        };
        proc.stdout.on('data', (d) => push(d.toString()));
        proc.stderr.on('data', (d) => push(d.toString()));
        let timedOut = false;
        const code = await new Promise((resolvePromise, reject) => {
            const timer = setTimeout(() => {
                timedOut = true;
                try {
                    proc.kill();
                }
                catch { /* already dead */ }
            }, timeoutMs);
            proc.on('error', (error) => {
                clearTimeout(timer);
                reject(error);
            });
            proc.on('close', (c) => {
                clearTimeout(timer);
                resolvePromise(c);
            });
        });
        return { code, timedOut, tail };
    }
    // ── step output summaries ─────────────────────────────────────────────────
    resDir() {
        return join(this.dir, 'res');
    }
    async summarizeNormalization() {
        const report = await readCsvIfExists(join(this.resDir(), 'norm_results', 'auto_imputation_report.csv'));
        const methods = { KNN: new Set(), Perseus: new Set(), Filtered: new Set() };
        for (const row of report) {
            const m = row.Method_Used;
            if (m && methods[m])
                methods[m].add(row.Accession);
        }
        const abundance = await readCsvIfExists(join(this.resDir(), 'norm_results', 'protein_abundance_data.csv'));
        const nSamples = abundance.length > 0 ? Object.keys(abundance[0]).length - 1 : 0;
        return {
            retainedProteins: abundance.length,
            samples: nSamples,
            imputedByKnn: methods.KNN.size,
            imputedByPerseus: methods.Perseus.size,
            filteredOut: methods.Filtered.size,
            reportFile: 'res/norm_results/auto_imputation_report.csv',
            abundanceFile: 'res/norm_results/protein_abundance_data.csv',
        };
    }
    async summarizePca() {
        const variance = await readCsvIfExists(join(this.resDir(), 'pca_results', 'pca_results_summary.csv'));
        const pc = {};
        for (const row of variance.slice(0, 3)) {
            pc[row.Component] = Number(row.Variance);
        }
        return {
            pc1: pc.PC1 ?? null,
            pc2: pc.PC2 ?? null,
            pc3: pc.PC3 ?? null,
            biplot: 'res/pca_results/pca_biplot_PC1_PC2.pdf',
            varianceFile: 'res/pca_results/pca_results_summary.csv',
            scoresFile: 'res/pca_results/pca_sample_scores.csv',
        };
    }
    comparisonDirs() {
        return listDirs(join(this.resDir(), 'dea_results'));
    }
    async summarizeBatch() {
        const performed = existsSync(join(this.resDir(), 'batch_removal_results.rds'));
        const assignments = await readCsvIfExists(join(this.resDir(), 'batch_removal_results', 'batch_assignments.csv'));
        const batches = [...new Set(assignments.map((r) => r.Batch).filter(Boolean))];
        return { performed, batches, pcaAfter: 'res/batch_removal_results/pca_after_correction/' };
    }
    async summarizeDea() {
        const comps = await this.comparisonDirs();
        const results = {};
        for (const comp of comps) {
            const base = join(this.resDir(), 'dea_results', comp);
            const thresholds = await readCsvIfExists(join(base, 'threshold_info.csv'));
            const regulated = await readCsvIfExists(join(base, 'regulated_data.csv'));
            let up = 0;
            let down = 0;
            const top = { up: [], down: [] };
            const ranked = regulated
                .map((r) => ({ ...r, lfc: Number(r.log2_fold_change) || 0, p: Number(r.p_value) || Number.NaN }))
                .sort((a, b) => Math.abs(b.lfc) - Math.abs(a.lfc));
            for (const r of regulated) {
                if (r.regulation_group === 'up')
                    up++;
                else if (r.regulation_group === 'down')
                    down++;
            }
            for (const r of ranked) {
                if (top.up.length < 5 && r.regulation_group === 'up')
                    top.up.push(r);
                if (top.down.length < 5 && r.regulation_group === 'down')
                    top.down.push(r);
            }
            const t = thresholds[0] ?? {};
            results[comp] = {
                fcThreshold: t.fc_threshold ? Number(t.fc_threshold) : null,
                pThreshold: t.p_threshold ? Number(t.p_threshold) : null,
                fcSource: t.fc_source ?? null,
                up,
                down,
                total: regulated.length,
                topUp: top.up.map((r) => ({ accession: r.Accession, gene: r.GeneName, log2fc: r.lfc, p: r.p })),
                topDown: top.down.map((r) => ({ accession: r.Accession, gene: r.GeneName, log2fc: r.lfc, p: r.p })),
                volcano: `res/dea_results/${comp}/volcano_plot.pdf`,
            };
        }
        return results;
    }
    async summarizeEnrichment() {
        const comps = await this.comparisonDirs();
        const results = {};
        for (const comp of comps) {
            const base = join(this.resDir(), 'dea_results', comp, 'enrichment_results');
            const go = await readCsvIfExists(join(base, 'analysis_all_go_results.csv'));
            const kegg = await readCsvIfExists(join(base, 'analysis_all_kegg_results.csv'));
            const topTerms = (rows, n) => rows
                .sort((a, b) => {
                const pa = Number(a.p_adjust ?? a['p.adjust'] ?? 1);
                const pb = Number(b.p_adjust ?? b['p.adjust'] ?? 1);
                return pa - pb;
            })
                .slice(0, n)
                .map((r) => ({
                id: r.ID,
                description: r.Description,
                pAdjust: Number(r.p_adjust ?? r['p.adjust']) || null,
                count: Number(r.Count),
            }));
            results[comp] = {
                goTerms: go.length,
                keggPathways: kegg.length,
                topGo: topTerms(go, 10),
                topKegg: topTerms(kegg, 10),
            };
        }
        return results;
    }
    async summarizeGsea() {
        const comps = await this.comparisonDirs();
        const results = {};
        for (const comp of comps) {
            const base = join(this.resDir(), 'dea_results', comp, 'gsea_results');
            const rows = await readCsvIfExists(join(base, 'gsea_results.csv'));
            const usable = rows.map((r) => ({ ...r, nes: Number(r.NES) || 0, padj: Number(r.p_adjust) || Number(r['p.adjust']) || Number.NaN }));
            const positive = usable.filter((r) => r.nes > 0).sort((a, b) => b.nes - a.nes).slice(0, 5);
            const negative = usable.filter((r) => r.nes < 0).sort((a, b) => a.nes - b.nes).slice(0, 5);
            const pick = (r) => ({ id: r.ID, description: r.Description, nes: r.nes, padj: r.padj });
            results[comp] = {
                totalSets: usable.length,
                topPositive: positive.map(pick),
                topNegative: negative.map(pick),
            };
        }
        return results;
    }
    async status() {
        const deaDirs = await this.comparisonDirs();
        const enrichDone = await (async () => {
            for (const comp of deaDirs) {
                const base = join(this.resDir(), 'dea_results', comp, 'enrichment_results');
                const go = await readCsvIfExists(join(base, 'analysis_all_go_results.csv'));
                const kegg = await readCsvIfExists(join(base, 'analysis_all_kegg_results.csv'));
                if (go.length > 0 || kegg.length > 0 || existsSync(join(base, 'analysis_all_go_results.csv')))
                    return true;
            }
            return false;
        })();
        const gseaDone = await (async () => {
            for (const comp of deaDirs) {
                if (existsSync(join(this.resDir(), 'dea_results', comp, 'gsea_results', 'gsea_results.csv')))
                    return true;
            }
            return false;
        })();
        return {
            normalization: existsSync(join(this.resDir(), 'normalization_results.rds')),
            pca: existsSync(join(this.resDir(), 'pca_results', 'pca_biplot_PC1_PC2.pdf')),
            batch: existsSync(join(this.resDir(), 'batch_removal_results.rds')),
            dea: deaDirs,
            enrichment: enrichDone,
            gsea: gseaDone,
        };
    }
}
export async function preflight(proteinFile, sampleInfoFile) {
    const text = await readFile(proteinFile, 'utf8');
    const lines = text.split(/\r?\n/);
    if (lines.length < 2)
        throw new Error('protein expression file is empty or has no data rows');
    const header = lines[0].split('\t');
    const metaCols = ['Accession', 'GeneName', 'Description'].filter((c) => header.includes(c));
    const sampleCols = header.filter((c) => !metaCols.includes(c));
    const dataRows = lines.slice(1).filter((l) => l.trim() !== '');
    const nProteins = dataRows.length;
    // Flag non-numeric columns that are being treated as samples: MaxQuant/PD
    // matrices commonly carry "Reverse", "Potential contaminant", "MS/MS count"
    // columns that must not feed the pipeline as samples.
    const nonNumericSampleColumns = sampleCols.filter((c) => {
        const idx = header.indexOf(c);
        const values = dataRows.map((l) => (l.split('\t')[idx] ?? '').trim());
        return looksNumeric(values) < 0.8;
    });
    // NA statistics + duplicates
    const naBuckets = { none: 0, low: 0, mid: 0, high: 0 };
    const accessions = new Set();
    let duplicateCount = 0;
    for (const line of dataRows) {
        const cells = line.split('\t');
        const acc = cells[0];
        if (accessions.has(acc))
            duplicateCount++;
        else
            accessions.add(acc);
        let na = 0;
        let total = 0;
        header.forEach((col, idx) => {
            if (!metaCols.includes(col)) {
                total++;
                const v = (cells[idx] ?? '').trim();
                if (v === '' || v === 'NaN' || v === 'NA' || v.toLowerCase() === 'nan')
                    na++;
            }
        });
        if (total > 0) {
            const ratio = na / total;
            if (ratio === 0)
                naBuckets.none++;
            else if (ratio < 0.6)
                naBuckets.low++;
            else if (ratio < 0.9)
                naBuckets.mid++;
            else
                naBuckets.high++;
        }
    }
    // group inference from sample names (strip trailing _<digits>)
    const inferGroup = (name) => String(name).replace(/[_\-.]\d+$/, '');
    const inferredGroups = [...new Set(sampleCols.map(inferGroup))];
    // sample info validation
    let sampleInfo = null;
    let batchColumn = false;
    let sampleInfoValid = true;
    let missingSamples = [];
    if (sampleInfoFile) {
        const infoText = await readFile(sampleInfoFile, 'utf8');
        const infoHeader = infoText.split(/\r?\n/)[0].split('\t');
        batchColumn = infoHeader.includes('Batch');
        const infoSamples = new Set(infoText.split(/\r?\n/).slice(1).filter((l) => l.trim() !== '').map((l) => l.split('\t')[0]));
        missingSamples = sampleCols.filter((s) => !infoSamples.has(s));
        sampleInfoValid = missingSamples.length === 0;
        sampleInfo = { columns: infoHeader, samples: infoSamples.size };
    }
    return {
        nProteins,
        nSamples: sampleCols.length,
        sampleColumns: sampleCols,
        metaColumns: metaCols,
        nonNumericSampleColumns,
        inferredGroups,
        duplicateAccessions: duplicateCount,
        naBuckets,
        batchColumn,
        sampleInfo,
        sampleInfoValid,
        missingSamples,
        recommendation: !sampleInfoFile
            ? 'sample_info.txt missing; the plugin will generate it with inferred groups — review before running'
            : sampleInfoValid
                ? 'sample metadata matches the expression matrix'
                : `sample metadata does NOT match: ${missingSamples.join(', ')}`,
    };
}
/** Write a generated sample_info.txt (inferred groups) into the project data dir. */
export async function writeGeneratedSampleInfo(projectDir, sampleColumns, groupOverrides = null) {
    mkdirSync(join(projectDir, 'data'), { recursive: true });
    const inferGroup = (name) => String(name).replace(/[_\-.]\d+$/, '');
    const rows = ['Sample\tGroup'];
    for (const s of sampleColumns) {
        const group = groupOverrides?.[s] ?? inferGroup(s);
        rows.push(`${s}\t${group}`);
    }
    await writeFile(join(projectDir, 'data', 'sample_info.txt'), rows.join('\n') + '\n', 'utf8');
}
