import { type ChildProcess } from 'node:child_process';
export declare const R_VERSION = "4.4.0";
export declare const BIOC_VERSION = "3.20";
export declare const DEFAULT_MIRRORS: {
    cran: string;
    bioc: string;
    rBase: string;
    fallbackCran: string;
    fallbackBioc: string;
    fallbackRBase: string;
};
export declare const LINUX_BINARY_CRAN = "https://packagemanager.posit.co/cran/__linux__/jammy/2024-11-15";
export interface RuntimeConfig {
    dataDir?: string;
    libraryDir?: string;
    rscript?: string;
    cranRepo?: string;
    biocRepo?: string;
    enableInstall?: boolean;
    defaultTimeoutMs?: number;
    backend?: string;
    dockerImage?: string;
    enableNetwork?: boolean;
}
export interface PackageManifest {
    rVersion?: string;
    cran: string[];
    bioc: string[];
}
export interface RuntimeStatus {
    ok: boolean;
    rscript: string | null;
    rVersion: string | null;
    libraryDir: string;
    missing: string[] | null;
    message: string;
}
export type LogSink = (chunk: string) => void;
export declare function sleep(ms: number): Promise<void>;
/** Kill a spawned process when the signal aborts (no-op without a signal). */
export declare function wireKillOnAbort(proc: ChildProcess, signal?: AbortSignal): void;
/** PATH lookup command + binary name for the current platform. */
export declare function pathLookupCommand(): {
    cmd: string;
    target: string;
};
export interface RPathCandidate {
    path: string;
    /** When true, the path is a root whose child dirs hold bin/Rscript(.exe). */
    directory: boolean;
    preferred?: boolean;
}
/**
 * Well-known R install locations probed by detectRscript, besides the
 * PATH lookup. Directory entries are scanned for version sub-directories
 * (R-4.4.0, R_4.4.0, ...).
 */
export declare function candidateScriptPaths(runtimeDir: string): RPathCandidate[];
/** Download with redirects, retries, and a per-attempt timeout. Returns the destination path. */
export declare function downloadFile(url: string, dest: string, opts?: {
    retries?: number;
    timeoutMs?: number;
}): Promise<string>;
export declare class Runtime {
    config: RuntimeConfig;
    dataDir: string;
    runtimeDir: string;
    downloadsDir: string;
    libraryDir: string;
    cranRepo: string;
    biocRepo: string;
    rBase: string;
    constructor(config?: RuntimeConfig);
    /** R version string like "4.4", or null when the executable is not R. */
    rVersion(rscript: string): string | null;
    whereRscript(): string | null;
    /** Locate a usable Rscript (config override → plugin-managed → common dirs → PATH). */
    detectRscript(): Promise<string | null>;
    /** Download and silently install the pinned R version into the managed dir (no admin). */
    installR(opts?: {
        onLog?: LogSink;
        signal?: AbortSignal;
    }): Promise<string>;
    /** Names of packages currently installed in the managed library. */
    installedPackages(rscript: string): Promise<string[]>;
    /** Install every manifest package that is missing from the managed library. */
    installPackages(rscript: string, manifest: PackageManifest, opts?: {
        onLog?: LogSink;
        timeoutMs?: number;
        signal?: AbortSignal;
    }): Promise<void>;
    /** Missing manifest packages (empty = complete library). */
    missingPackages(rscript: string, manifest: PackageManifest): Promise<string[]>;
    /**
     * Runtime capability probe: loads every manifest package and exercises the
     * heavy pipeline code paths (PCAtools encircle/ggalt, ComBat, enricher).
     * Catches Suggests-only gaps that static manifest checks cannot see.
     */
    verifyRuntime(rscript: string, manifest: PackageManifest, opts?: {
        onLog?: LogSink;
        timeoutMs?: number;
        signal?: AbortSignal;
    }): Promise<{
        ok: boolean;
        failures: string[];
        tail: string;
    }>;
    /** Persisted backend choice (written by environment setup, read by steps). */
    statePath(): string;
    getState(): Promise<{
        backend?: 'local' | 'docker';
        dockerImage?: string;
    }>;
    private stateQueue;
    setState(patch: {
        backend?: 'local' | 'docker';
        dockerImage?: string;
    }): Promise<void>;
    dockerAvailable(): boolean;
    dockerImageReady(image: string): Promise<boolean>;
    dockerPull(image: string, opts?: {
        onLog?: LogSink;
        timeoutMs?: number;
        signal?: AbortSignal;
    }): Promise<void>;
    /** Run the runtime probe INSIDE the image (the image carries check_runtime.R). */
    dockerVerify(image: string, opts?: {
        onLog?: LogSink;
        timeoutMs?: number;
        signal?: AbortSignal;
    }): Promise<{
        ok: boolean;
        failures: string[];
    }>;
    /** Extract a previously created offline snapshot zip into the managed runtime dir. */
    restoreSnapshot(snapshotPath: string, opts?: {
        onLog?: LogSink;
        timeoutMs?: number;
        signal?: AbortSignal;
    }): Promise<void>;
    /** Full environment health report. */
    status(manifest?: PackageManifest): Promise<RuntimeStatus>;
}
