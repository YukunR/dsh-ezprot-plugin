// ProteomicsService: the orchestration surface behind the agent tools.
// Every pipeline step runs as its own call so each one lands in the harness
// trajectory with a structured summary.
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { Runtime } from './runtime.js';
import { Backgrounds, ORGANISMS, packageDir } from './backgrounds.js';
import { Project, preflight, writeGeneratedSampleInfo } from './pipeline.js';
export const STEPS = ['normalization', 'pca', 'batch_remove', 'dea', 'enrich', 'gsea', 'all'];
function fmt(n) {
    if (n === null || n === undefined || Number.isNaN(n))
        return 'NA';
    const num = Number(n);
    if (Math.abs(num) >= 100)
        return num.toFixed(0);
    if (Math.abs(num) >= 1)
        return num.toFixed(2).replace(/\.?0+$/, '');
    return num.toFixed(2);
}
function compNameLine(comp) {
    const control = Array.isArray(comp.control) ? comp.control.join('+') : comp.control;
    const treatment = Array.isArray(comp.treatment) ? comp.treatment.join('+') : comp.treatment;
    return `${control} vs ${treatment} (${comp.name ?? 'unnamed'})`;
}
export class ProteomicsService {
    config;
    runtime;
    backgrounds;
    manifestPromise = null;
    locks = new Map();
    timeoutMs;
    constructor(config = {}) {
        this.config = config;
        this.runtime = new Runtime(config);
        this.backgrounds = new Backgrounds(this.runtime, config);
        this.timeoutMs = config.defaultTimeoutMs || 30 * 60 * 1000;
    }
    loadManifest() {
        if (!this.manifestPromise) {
            this.manifestPromise = readFile(join(packageDir, 'manifest', 'packages.json'), 'utf8').then((text) => JSON.parse(text));
        }
        return this.manifestPromise;
    }
    withLock(key, fn) {
        const previous = this.locks.get(key) ?? Promise.resolve();
        const next = previous.catch(() => { }).then(fn);
        this.locks.set(key, next);
        return next.finally(() => {
            if (this.locks.get(key) === next)
                this.locks.delete(key);
        });
    }
    // ── environment ───────────────────────────────────────────────────────────
    async dockerAvailable() {
        try {
            const res = spawnSync('docker', ['--version'], { encoding: 'utf8', timeout: 15000, windowsHide: true });
            return res.status === 0;
        }
        catch {
            return false;
        }
    }
    async environmentStatus() {
        const manifest = await this.loadManifest();
        const status = await this.runtime.status(manifest);
        const orgs = {};
        for (const org of Object.keys(ORGANISMS))
            orgs[org] = this.backgrounds.status(org);
        const docker = await this.dockerAvailable();
        return { ...status, dockerAvailable: docker, dockerImage: this.config.dockerImage ?? 'ezprot:latest', organisms: orgs, dataDir: this.runtime.dataDir };
    }
    async environmentSetup(opts = {}) {
        const { action, snapshotPath, onLog } = opts;
        const log = onLog ?? (() => { });
        const manifest = await this.loadManifest();
        const status = await this.environmentStatus();
        if (action === 'status' || action === undefined)
            return status;
        let rscript = await this.runtime.detectRscript();
        if (!rscript) {
            if (this.config.enableInstall === false) {
                throw new Error('no R installation found and automatic installation is disabled (enableInstall: false); install R 4.4.x manually or set rscript in the plugin config');
            }
            log(`no R installation found — installing R ${manifest.rVersion ?? '4.4.0'} into the plugin-managed directory (no admin rights needed) ...`);
            rscript = await this.runtime.installR({ onLog });
        }
        else {
            log(`using R at ${rscript} (${this.runtime.rVersion(rscript)})`);
        }
        if (action === 'restore_snapshot') {
            if (!snapshotPath)
                throw new Error('snapshotPath is required for restore_snapshot');
            await this.runtime.restoreSnapshot(snapshotPath, { onLog });
            return this.environmentStatus();
        }
        const missing = await this.runtime.missingPackages(rscript, manifest);
        if (missing.length === 0) {
            log('all required R packages are already installed — nothing to do');
            return this.environmentStatus();
        }
        if (this.config.enableInstall === false) {
            log(`${missing.length} package(s) missing: ${missing.join(', ')} — automatic installation is disabled`);
            return this.environmentStatus();
        }
        log(`${missing.length} package(s) missing, installing once into ${this.runtime.libraryDir} (mirrors: ${this.runtime.cranRepo}, ${this.runtime.biocRepo}) ...`);
        await this.runtime.installPackages(rscript, manifest, { onLog, timeoutMs: 45 * 60 * 1000 });
        return this.environmentStatus();
    }
    // ── backgrounds ───────────────────────────────────────────────────────────
    async backgroundEnsure(organism, opts = {}) {
        return this.backgrounds.ensure(organism, opts);
    }
    // ── preflight ─────────────────────────────────────────────────────────────
    async preflightProject(opts) {
        const { projectDir, proteinFile, sampleInfoFile = null, organism, organismName, comparisons = null, params } = opts;
        if (!ORGANISMS[organism])
            throw new Error(`unknown organism '${organism}' (supported: ${Object.keys(ORGANISMS).join(', ')})`);
        const project = new Project(projectDir);
        const qc = await preflight(proteinFile, sampleInfoFile);
        let generatedSampleInfo = false;
        let effectiveSampleInfoFile = sampleInfoFile;
        if (!effectiveSampleInfoFile) {
            // sample metadata is required by every step; generate it from inferred
            // groups and flag it for user review.
            await writeGeneratedSampleInfo(project.dir, qc.sampleColumns);
            generatedSampleInfo = true;
            effectiveSampleInfoFile = join(project.dir, 'data', 'sample_info.txt');
        }
        const backgroundStatus = this.backgrounds.status(organism);
        const org = ORGANISMS[organism];
        await project.create({
            proteinFile,
            sampleInfoFile: effectiveSampleInfoFile,
            organism,
            organismName: organismName ?? org.name,
            comparisons,
            params,
            backgrounds: {
                go: this.backgrounds.goPath(organism),
                kegg: this.backgrounds.keggPath(organism),
            },
        });
        const lines = [];
        lines.push(`preflight OK — project at ${project.dir}`);
        lines.push(`organism: ${org.name} (KEGG ${org.kegg}, taxon ${org.taxon})`);
        lines.push(`data: ${qc.nProteins} proteins × ${qc.nSamples} samples`);
        lines.push(`inferred groups: ${qc.inferredGroups.join(', ')}`);
        lines.push(`NA pattern: ${qc.naBuckets.none} complete, ${qc.naBuckets.low} <60%, ${qc.naBuckets.mid} 60-90% (Perseus), ${qc.naBuckets.high} >=90% (discard)`);
        if (qc.duplicateAccessions > 0)
            lines.push(`WARNING: ${qc.duplicateAccessions} duplicate Accession(s) — pipeline stops with an error; fix the input first`);
        if (generatedSampleInfo)
            lines.push('sample_info.txt generated from inferred groups — have the user review group assignments');
        else if (effectiveSampleInfoFile) {
            lines.push(`sample metadata: ${qc.sampleInfo?.samples} samples${qc.batchColumn ? ' (Batch column present — batch removal available)' : ' (no Batch column; batch removal will be skipped)'}`);
            if (!qc.sampleInfoValid)
                lines.push(`WARNING: ${qc.missingSamples.length} sample(s) in the expression matrix missing from metadata: ${qc.missingSamples.join(', ')}`);
        }
        lines.push(`backgrounds: GO ${backgroundStatus.go ? 'ready' : 'will be built on demand'}, KEGG ${backgroundStatus.kegg ? 'ready' : 'will be built on demand'} (cached at ${backgroundStatus.cacheDir})`);
        if (comparisons && comparisons.length > 0) {
            lines.push(`comparisons: ${comparisons.map(compNameLine).join('; ')}`);
        }
        else {
            lines.push('comparisons: NOT SET — confirm with the user which groups to compare, then call proteomics_step with the first step (it will ask to set them) or re-run preflight with comparisons');
        }
        lines.push('next: proteomics_step step=normalization, then pca, (batch_remove if Batch column), dea, enrich, gsea');
        return lines.join('\n');
    }
    /** backend: 'auto' → docker only when no local R exists but Docker does. */
    resolveBackend(hasLocalR, hasDocker) {
        const configured = this.config.backend || 'auto';
        if (configured === 'local')
            return 'local';
        if (configured === 'docker')
            return 'docker';
        if (hasLocalR)
            return 'local';
        if (hasDocker)
            return 'docker';
        return 'local';
    }
    // ── step execution ────────────────────────────────────────────────────────
    async runStep(opts) {
        const { projectDir, step, rerun = false, params, onLog } = opts;
        if (!STEPS.includes(step))
            throw new Error(`unknown step '${step}' (valid: ${STEPS.join(', ')})`);
        const project = new Project(projectDir);
        return this.withLock(project.dir, async () => {
            const state = project.loadState();
            if (!state)
                throw new Error(`no project state at ${project.dir} — run proteomics_preflight first`);
            if (!state.comparisons || state.comparisons.length === 0) {
                throw new Error('comparisons not set — run proteomics_preflight with the confirmed comparisons');
            }
            if (params && typeof params === 'object' && Object.keys(params).length > 0) {
                state.params = { ...(state.params ?? {}), ...params };
                project.saveState(state);
            }
            // runtime readiness (no surprise installs inside a step)
            const manifest = await this.loadManifest();
            const rscript = await this.runtime.detectRscript();
            const dockerOk = await this.dockerAvailable();
            const backend = this.resolveBackend(rscript !== null, dockerOk);
            if (backend !== 'docker') {
                if (!rscript)
                    throw new Error('no R installation found — run proteomics_environment action=setup first');
                const missing = await this.runtime.missingPackages(rscript, manifest);
                if (missing.length > 0) {
                    throw new Error(`${missing.length} R package(s) missing (${missing.slice(0, 10).join(', ')}${missing.length > 10 ? '…' : ''}) — run proteomics_environment action=setup first`);
                }
            }
            else if (!dockerOk) {
                throw new Error(`backend '${this.config.backend}' requires Docker, but it is unavailable`);
            }
            // backgrounds required by enrichment/gsea steps
            if (step === 'enrich' || step === 'gsea' || step === 'all') {
                const log = onLog ?? (() => { });
                const bs = this.backgrounds.status(state.organism);
                if (!bs.go || !bs.kegg) {
                    log(`building missing ${state.organism} annotation backgrounds (one-time, cached) ...`);
                    await this.backgrounds.ensure(state.organism, { onLog });
                }
            }
            project.regenerateMainR(state);
            const log = onLog ?? (() => { });
            const rStep = step === 'batch_remove' ? 'batch-removal' : step;
            const res = await project.runStep(this.runtime, rStep, {
                rerun,
                timeoutMs: this.timeoutMs,
                onLog: log,
                backend,
                dockerImage: this.config.dockerImage ?? 'ezprot:latest',
            });
            if (res.timedOut)
                throw new Error(`step ${step} timed out after ${this.timeoutMs}ms`);
            if (res.code !== 0) {
                throw new Error(`step ${step} failed (exit ${res.code})\n${res.tail.slice(-4000)}`);
            }
            const summary = await this.stepSummary(project, step, state);
            const lines = [`step ${step} OK (project: ${project.dir})`];
            lines.push(...this.formatSummary(step, summary));
            if (res.tail.trim().length > 0) {
                lines.push(`R log tail: ${res.tail.trim().split(/\r?\n/).slice(-12).join('\n')}`);
            }
            return lines.join('\n');
        });
    }
    async stepSummary(project, step, _state) {
        switch (step) {
            case 'normalization':
                return { normalization: await project.summarizeNormalization() };
            case 'pca':
                return { pca: await project.summarizePca() };
            case 'batch_remove':
                return { batch: await project.summarizeBatch() };
            case 'dea':
                return { dea: await project.summarizeDea() };
            case 'enrich':
                return { enrichment: await project.summarizeEnrichment() };
            case 'gsea':
                return { gsea: await project.summarizeGsea() };
            case 'all':
                return {
                    normalization: await project.summarizeNormalization(),
                    pca: await project.summarizePca(),
                    batch: await project.summarizeBatch(),
                    dea: await project.summarizeDea(),
                    enrichment: await project.summarizeEnrichment(),
                    gsea: await project.summarizeGsea(),
                };
            default:
                return {};
        }
    }
    formatSummary(step, summary) {
        const lines = [];
        if (summary.normalization) {
            const n = summary.normalization;
            lines.push(`normalization: ${n.retainedProteins} proteins retained across ${n.samples} samples; KNN-imputed ${n.imputedByKnn}, Perseus-imputed ${n.imputedByPerseus}, discarded ${n.filteredOut}`);
        }
        if (summary.pca) {
            const p = summary.pca;
            lines.push(`pca: PC1 ${fmt(p.pc1)}%, PC2 ${fmt(p.pc2)}%, PC3 ${fmt(p.pc3)}% variance — biplot: ${p.biplot}`);
        }
        if (summary.batch) {
            const b = summary.batch;
            lines.push(b.performed
                ? `batch removal: performed with batches [${b.batches.join(', ')}] — corrected PCA at ${b.pcaAfter}`
                : 'batch removal: skipped (no Batch column in sample_info.txt)');
        }
        if (summary.dea) {
            for (const [comp, d] of Object.entries(summary.dea)) {
                lines.push(`${comp}: ${d.up} up / ${d.down} down (FC ${fmt(d.fcThreshold)}, p ${fmt(d.pThreshold)}, source: ${d.fcSource}); volcano: ${d.volcano}`);
                if (d.topUp.length > 0)
                    lines.push(`  top up: ${d.topUp.map((r) => `${r.gene}(${fmt(r.log2fc)})`).join(', ')}`);
                if (d.topDown.length > 0)
                    lines.push(`  top down: ${d.topDown.map((r) => `${r.gene}(${fmt(r.log2fc)})`).join(', ')}`);
            }
        }
        if (summary.enrichment) {
            for (const [comp, e] of Object.entries(summary.enrichment)) {
                lines.push(`${comp} enrichment: ${e.goTerms} GO terms, ${e.keggPathways} KEGG pathways (all regulated)` +
                    (e.topGo.length > 0 ? `; top GO: ${e.topGo.slice(0, 5).map((t) => `${t.description} (p.adjust=${fmt(t.pAdjust)})`).join(' | ')}` : '') +
                    (e.topKegg.length > 0 ? `; top KEGG: ${e.topKegg.slice(0, 5).map((t) => `${t.description} (p.adjust=${fmt(t.pAdjust)})`).join(' | ')}` : ''));
            }
        }
        if (summary.gsea) {
            for (const [comp, g] of Object.entries(summary.gsea)) {
                lines.push(`${comp} GSEA: ${g.totalSets} gene sets evaluated` +
                    (g.topPositive.length > 0 ? `; top activated: ${g.topPositive.map((t) => `${t.description} (NES=${fmt(t.nes)})`).join(' | ')}` : '') +
                    (g.topNegative.length > 0 ? `; top suppressed: ${g.topNegative.map((t) => `${t.description} (NES=${fmt(t.nes)})`).join(' | ')}` : ''));
            }
        }
        return lines;
    }
    // ── report ────────────────────────────────────────────────────────────────
    async report(projectDir) {
        const project = new Project(projectDir);
        const state = project.loadState();
        if (!state)
            throw new Error(`no project state at ${project.dir} — run proteomics_preflight first`);
        const status = await project.status();
        const summary = await this.stepSummary(project, 'all', state);
        const lines = [];
        lines.push(`project: ${project.dir}`);
        lines.push(`organism: ${state.organismName ?? state.organism}; comparisons: ${(state.comparisons ?? []).map(compNameLine).join('; ')}`);
        lines.push(`completed: ${status.normalization ? 'normalization ' : ''}${status.pca ? 'pca ' : ''}${status.batch ? 'batch_removal ' : ''}${status.dea.length > 0 ? 'dea[' + status.dea.join(',') + '] ' : ''}${status.enrichment ? 'enrichment ' : ''}${status.gsea ? 'gsea ' : ''}`);
        lines.push(...this.formatSummary('all', summary));
        lines.push('interpretation: use web_search (UniProt/literature) for the top proteins and pathways above, then write the biologist-facing report (overview → top proteins → pathways → GSEA → candidate targets/experiments).');
        return lines.join('\n');
    }
}
