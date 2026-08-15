// Runtime facade: keeps the long-standing public API (one Runtime class) while
// each concern — R detection/install, package library, docker, state, snapshot
// restore — lives in its own module.
import { homedir } from 'node:os';
import { join } from 'node:path';
import { DEFAULT_MIRRORS } from './constants.js';
import { dockerAvailable, dockerImageReady, dockerPull, dockerVerify } from './docker.js';
import { installPackages, missingPackages, verifyRuntime, installedPackages } from './packages.js';
import { detectRscript, installR, rVersion } from './r-detect.js';
import { restoreSnapshot } from './snapshot.js';
import { StateStore } from './state.js';
export class Runtime {
    config;
    dataDir;
    runtimeDir;
    downloadsDir;
    libraryDir;
    cranRepo;
    biocRepo;
    rBase;
    state;
    constructor(config = {}) {
        this.config = config;
        this.dataDir = config.dataDir || join(process.env.DSH_HOME || join(homedir(), '.dsh'), 'proteomics');
        this.runtimeDir = join(this.dataDir, 'runtime');
        this.downloadsDir = join(this.dataDir, 'downloads');
        this.libraryDir = config.libraryDir || join(this.runtimeDir, 'library');
        this.cranRepo = config.cranRepo || DEFAULT_MIRRORS.cran;
        this.biocRepo = config.biocRepo || DEFAULT_MIRRORS.bioc;
        this.rBase = DEFAULT_MIRRORS.rBase;
        this.state = new StateStore(this.dataDir);
    }
    paths() {
        return {
            dataDir: this.dataDir,
            runtimeDir: this.runtimeDir,
            downloadsDir: this.downloadsDir,
            libraryDir: this.libraryDir,
            cranRepo: this.cranRepo,
            biocRepo: this.biocRepo,
            rBase: this.rBase,
        };
    }
    // ── R detection + installation ────────────────────────────────────────────
    rVersion(rscript) {
        return rVersion(rscript);
    }
    detectRscript() {
        return detectRscript({ ...this.paths(), rscript: this.config.rscript });
    }
    installR(opts = {}) {
        return installR({ ...this.paths(), rscript: this.config.rscript }, opts);
    }
    // ── package library ───────────────────────────────────────────────────────
    installedPackages(rscript) {
        return installedPackages(this.paths(), rscript);
    }
    installPackages(rscript, manifest, opts = {}) {
        return installPackages(this.paths(), rscript, manifest, opts);
    }
    missingPackages(rscript, manifest) {
        return missingPackages(this.paths(), rscript, manifest);
    }
    verifyRuntime(rscript, manifest, opts = {}) {
        return verifyRuntime(this.paths(), rscript, manifest, opts);
    }
    // ── persisted state ───────────────────────────────────────────────────────
    statePath() {
        return this.state.path();
    }
    getState() {
        return this.state.get();
    }
    setState(patch) {
        return this.state.set(patch);
    }
    // ── docker backend ────────────────────────────────────────────────────────
    dockerAvailable() {
        return dockerAvailable();
    }
    dockerImageReady(image) {
        return dockerImageReady(image);
    }
    dockerPull(image, opts = {}) {
        return dockerPull(image, opts);
    }
    dockerVerify(image, opts = {}) {
        return dockerVerify(image, opts);
    }
    // ── offline snapshot ──────────────────────────────────────────────────────
    restoreSnapshot(snapshotPath, opts = {}) {
        return restoreSnapshot(this.paths(), snapshotPath, opts);
    }
    /** Full environment health report. */
    async status(manifest) {
        const rscript = await this.detectRscript();
        if (!rscript) {
            return { ok: false, rscript: null, rVersion: null, libraryDir: this.libraryDir, missing: [], message: 'no R installation found (run environment setup)' };
        }
        const rv = this.rVersion(rscript);
        let missing = [];
        try {
            missing = await this.missingPackages(rscript, manifest ?? { cran: [], bioc: [] });
        }
        catch {
            missing = null; // library probe failed
        }
        return {
            ok: rv !== null && missing !== null && missing.length === 0,
            rscript,
            rVersion: rv,
            libraryDir: this.libraryDir,
            missing,
            message: missing === null
                ? 'package library could not be probed'
                : missing.length === 0
                    ? 'runtime ready'
                    : `${missing.length} package(s) missing`,
        };
    }
}
