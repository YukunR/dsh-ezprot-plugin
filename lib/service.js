// ProteomicsService: the orchestration surface behind the agent tools.
// Every pipeline step runs as its own call so each one lands in the harness
// trajectory with a structured summary.
import { readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { Runtime } from './runtime.js';
import { Backgrounds, ORGANISMS, packageDir } from './backgrounds.js';
import { Project, preflight, writeGeneratedSampleInfo } from './pipeline.js';
import { inspectRawFile, tidyRawFile } from './import.js';
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
        return this.runtime.dockerAvailable();
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
        const { action, snapshotPath, backend, onLog } = opts;
        const log = onLog ?? (() => { });
        const manifest = await this.loadManifest();
        const status = await this.environmentStatus();
        if (action === 'status' || action === undefined)
            return status;
        // Docker backend: pull the published image and verify it in-container.
        if (backend === 'docker') {
            if (!status.dockerAvailable) {
                throw new Error('Docker is not available on this machine — install Docker first, or use backend=local for the managed R install');
            }
            const image = this.config.dockerImage ?? 'ezprot:latest';
            if (!(await this.runtime.dockerImageReady(image))) {
                log(`pulling ${image} (one-time, a few minutes) ...`);
                await this.runtime.dockerPull(image, { onLog });
            }
            else {
                log(`image ${image} already present`);
            }
            log(`running the runtime probe inside ${image} ...`);
            const verify = await this.runtime.dockerVerify(image, { onLog });
            if (!verify.ok) {
                throw new Error(`docker image ${image} failed the runtime probe:\n${verify.failures.map((f) => `  - ${f}`).join('\n')}`);
            }
            log(`docker environment ready (${image})`);
            await this.runtime.setState({ backend: 'docker', dockerImage: image });
            return this.environmentStatus();
        }
        // Local backend: managed R + package library (also runs for restore_snapshot).
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
            await this.runtime.setState({ backend: 'local' });
            return this.environmentStatus();
        }
        const missing = await this.runtime.missingPackages(rscript, manifest);
        if (missing.length === 0) {
            log('all required R packages are already installed — nothing to do');
            await this.runtime.setState({ backend: 'local' });
            return this.environmentStatus();
        }
        if (this.config.enableInstall === false) {
            log(`${missing.length} package(s) missing: ${missing.join(', ')} — automatic installation is disabled`);
            return this.environmentStatus();
        }
        log(`${missing.length} package(s) missing, installing once into ${this.runtime.libraryDir} (mirrors: ${this.runtime.cranRepo}, ${this.runtime.biocRepo}) ...`);
        await this.runtime.installPackages(rscript, manifest, { onLog, timeoutMs: 45 * 60 * 1000 });
        await this.runtime.setState({ backend: 'local' });
        return this.environmentStatus();
    }
    // ── backgrounds ───────────────────────────────────────────────────────────
    async backgroundEnsure(organism, opts = {}) {
        return this.backgrounds.ensure(organism, opts);
    }
    // ── preflight ─────────────────────────────────────────────────────────────
    async preflightProject(opts) {
        const { projectDir, proteinFile, sampleInfoFile = null, organism, organismName, params } = opts;
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
            comparisons: null,
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
        lines.push('comparisons: NOT SET — ask the user which groups to compare (ask_user_question with candidate pairs), then call proteomics_compare with the confirmed comparisons');
        lines.push('next: proteomics_compare, then proteomics_step step=normalization → pca → (batch_remove if Batch column) → dea → enrich → gsea');
        return lines.join('\n');
    }
    /** Set the project comparisons (lightweight; regenerates main.R only). */
    async setComparisons(projectDir, comparisons) {
        const project = new Project(projectDir);
        const state = project.loadState();
        if (!state)
            throw new Error(`no project state at ${project.dir} — run proteomics_preflight first`);
        if (!comparisons || comparisons.length === 0)
            throw new Error('at least one comparison is required');
        state.comparisons = comparisons;
        project.saveState(state);
        project.regenerateMainR(state);
        const lines = [
            `comparisons set for ${project.dir}:`,
            ...comparisons.map(compNameLine),
            'main.R regenerated; ready for proteomics_step step=normalization',
        ];
        return lines.join('\n');
    }
    // ── batch assignments (injected AFTER PCA, when the user has seen the plots) ──
    sampleInfoPath(project) {
        return join(project.dir, 'data', 'sample_info.txt');
    }
    async readSampleInfo(project) {
        const text = await readFile(this.sampleInfoPath(project), 'utf8');
        const lines = text.split(/\r?\n/).filter((l) => l.trim() !== '');
        if (lines.length < 2)
            throw new Error(`sample_info.txt is empty at ${this.sampleInfoPath(project)}`);
        return { header: lines[0].split('\t'), rows: lines.slice(1).map((l) => l.split('\t')) };
    }
    /** Current samples, groups, and any existing Batch column of a project. */
    async batchList(projectDir) {
        const project = new Project(projectDir);
        const info = await this.readSampleInfo(project);
        const sampleIdx = info.header.indexOf('Sample');
        const groupIdx = info.header.indexOf('Group');
        const batchIdx = info.header.indexOf('Batch');
        if (sampleIdx < 0)
            throw new Error('sample_info.txt has no Sample column');
        const lines = [`${info.rows.length} samples in ${project.dir}`];
        for (const row of info.rows) {
            lines.push(`  ${row[sampleIdx]}\t${groupIdx >= 0 ? row[groupIdx] : '?'}\t${batchIdx >= 0 && row[batchIdx] ? `batch ${row[batchIdx]}` : '(no batch)'}`);
        }
        if (batchIdx < 0) {
            lines.push('no Batch column yet — after the user describes batch structure, use action=set with the sample→batch mapping');
        }
        return lines.join('\n');
    }
    /** Write/update the Batch column from a sample→batch mapping. */
    async setBatch(projectDir, mapping) {
        const project = new Project(projectDir);
        const info = await this.readSampleInfo(project);
        const sampleIdx = info.header.indexOf('Sample');
        if (sampleIdx < 0)
            throw new Error('sample_info.txt has no Sample column');
        let batchIdx = info.header.indexOf('Batch');
        const header = batchIdx < 0 ? [...info.header, 'Batch'] : info.header;
        if (batchIdx < 0)
            batchIdx = header.length - 1;
        const rows = info.rows.map((row) => {
            const r = [...row];
            while (r.length < header.length)
                r.push('');
            const sample = r[sampleIdx];
            r[batchIdx] = mapping[sample] ?? r[batchIdx] ?? '';
            return r;
        });
        const text = [header.join('\t'), ...rows.map((r) => r.join('\t'))].join('\n') + '\n';
        await writeFile(this.sampleInfoPath(project), text, 'utf8');
        const batches = [...new Set(rows.map((r) => r[batchIdx]).filter(Boolean))];
        return [
            `Batch column written for ${project.dir} (${batches.length} batch(es): ${batches.join(', ')})`,
            'next: proteomics_step step=batch_remove, then proteomics_step step=pca rerun=true to verify the correction',
        ].join('\n');
    }
    /** Remove the Batch column (revert batch assignments). */
    async clearBatch(projectDir) {
        const project = new Project(projectDir);
        const info = await this.readSampleInfo(project);
        const batchIdx = info.header.indexOf('Batch');
        if (batchIdx < 0)
            return 'no Batch column present — nothing to clear';
        const header = info.header.filter((_, i) => i !== batchIdx);
        const rows = info.rows.map((row) => row.filter((_, i) => i !== batchIdx));
        await writeFile(this.sampleInfoPath(project), [header.join('\t'), ...rows.map((r) => r.join('\t'))].join('\n') + '\n', 'utf8');
        return 'Batch column removed';
    }
    /** Inspect a raw biologist file (TSV/CSV/Excel) before tidying. */
    async inspectRaw(inputFile, opts = {}) {
        return inspectRawFile(inputFile, this.runtime, opts);
    }
    /** Deep runtime check: missing packages + heavy-path capability probe. */
    async verifyRuntimeReport() {
        const manifest = await this.loadManifest();
        const rscript = await this.runtime.detectRscript();
        if (!rscript)
            throw new Error('no R installation found — run proteomics_environment action=setup first');
        const lines = [];
        const missing = await this.runtime.missingPackages(rscript, manifest);
        if (missing.length > 0) {
            lines.push(`packages missing from the managed library: ${missing.join(', ')}`);
        }
        else {
            lines.push('all manifest packages present');
        }
        const probe = await this.runtime.verifyRuntime(rscript, manifest);
        if (probe.ok) {
            lines.push('runtime probe: ALL OK (package loads, PCAtools biplot/encircle, ComBat, enricher)');
        }
        else {
            lines.push('runtime probe FAILED — the pipeline will break until fixed:');
            for (const f of probe.failures)
                lines.push(`  - ${f}`);
            if (probe.tail.trim())
                lines.push(`probe tail: ${probe.tail.slice(-1500)}`);
        }
        return lines.join('\n');
    }
    /** Tidy a raw biologist file into the canonical matrix + sample info. */
    async tidyRaw(inputFile, outputDir, opts) {
        const result = await tidyRawFile(inputFile, this.runtime, outputDir, opts);
        return [
            `tidy OK — ${result.keptRows} proteins kept (${result.droppedRows} rows dropped, ${result.duplicateAccessions} duplicate accessions)`,
            `protein matrix: ${result.proteinFile}`,
            `sample info: ${result.sampleInfoFile} (groups: ${result.groups.join(', ')})`,
            'review the sample_info.txt groups with the user, then run proteomics_preflight with these files',
        ].join('\n');
    }
    /** PNG files produced by a step, for chat display (project-relative). */
    async stepImages(projectDir, step) {
        return this.stepImagePaths(new Project(projectDir), step);
    }
    async stepImagePaths(project, step) {
        const paths = [];
        if (step === 'pca') {
            for (const f of ['sample_correlation_heatmap.png', 'sample_dendrogram_colored.png', 'pca_biplot_PC1_PC2.png', 'pca_variance_explained.png']) {
                paths.push(join('res', 'pca_results', f));
            }
        }
        if (step === 'dea' || step === 'all') {
            const comps = await project.comparisonDirs();
            for (const comp of comps)
                paths.push(join('res', 'dea_results', comp, 'volcano_plot.png'));
        }
        return paths.filter((rel) => existsSync(join(project.dir, rel)));
    }
    /**
     * Backend resolution order: explicit config (local/docker) → persisted
     * setup choice (runtime-state.json) → auto (local R preferred; docker only
     * when no local R exists but Docker does).
     */
    async resolveBackend(hasLocalR, hasDocker) {
        const configured = this.config.backend || 'auto';
        if (configured === 'local')
            return 'local';
        if (configured === 'docker')
            return 'docker';
        const state = await this.runtime.getState();
        if (state.backend === 'docker') {
            if (!hasDocker)
                throw new Error('the project backend was set to Docker, but Docker is not available on this machine');
            return 'docker';
        }
        if (state.backend === 'local')
            return 'local';
        if (hasLocalR)
            return 'local';
        if (hasDocker)
            return 'docker';
        return 'local';
    }
    /**
     * Verify the docker backend can actually run a step: the CLI must be
     * present AND the image must already be pulled. Without this, `docker run`
     * would implicitly pull (unbounded, no progress feed) and fail confusingly.
     */
    async assertDockerReady(image, dockerOk) {
        if (!dockerOk) {
            throw new Error('the docker backend was selected, but Docker is unavailable on this machine');
        }
        if (!(await this.runtime.dockerImageReady(image))) {
            throw new Error(`docker image ${image} is not present on this machine — run proteomics_environment action=setup with backend=docker first (or switch the backend)`);
        }
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
            const backend = await this.resolveBackend(rscript !== null, dockerOk);
            const runtimeState = await this.runtime.getState();
            const dockerImage = runtimeState.dockerImage ?? this.config.dockerImage ?? 'ezprot:latest';
            if (backend !== 'docker') {
                if (!rscript)
                    throw new Error('no R installation found — run proteomics_environment action=setup first');
                const missing = await this.runtime.missingPackages(rscript, manifest);
                if (missing.length > 0) {
                    throw new Error(`${missing.length} R package(s) missing (${missing.slice(0, 10).join(', ')}${missing.length > 10 ? '…' : ''}) — run proteomics_environment action=setup first`);
                }
            }
            else {
                await this.assertDockerReady(dockerImage, dockerOk);
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
                dockerImage,
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
