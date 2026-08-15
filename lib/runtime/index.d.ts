import type { LogSink, PackageManifest, RuntimeConfig, RuntimeStatus } from './types.js';
export declare class Runtime {
    config: RuntimeConfig;
    dataDir: string;
    runtimeDir: string;
    downloadsDir: string;
    libraryDir: string;
    cranRepo: string;
    biocRepo: string;
    rBase: string;
    private state;
    constructor(config?: RuntimeConfig);
    private paths;
    rVersion(rscript: string): string | null;
    detectRscript(): Promise<string | null>;
    installR(opts?: {
        onLog?: LogSink;
        signal?: AbortSignal;
    }): Promise<string>;
    installedPackages(rscript: string): Promise<string[]>;
    installPackages(rscript: string, manifest: PackageManifest, opts?: {
        onLog?: LogSink;
        timeoutMs?: number;
        signal?: AbortSignal;
    }): Promise<void>;
    missingPackages(rscript: string, manifest: PackageManifest): Promise<string[]>;
    verifyRuntime(rscript: string, manifest: PackageManifest, opts?: {
        onLog?: LogSink;
        timeoutMs?: number;
        signal?: AbortSignal;
    }): Promise<{
        ok: boolean;
        failures: string[];
        tail: string;
    }>;
    statePath(): string;
    getState(): Promise<{
        backend?: 'local' | 'docker';
        dockerImage?: string;
    }>;
    setState(patch: {
        backend?: 'local' | 'docker';
        dockerImage?: string;
    }): Promise<void>;
    dockerAvailable(): boolean;
    dockerImageReady(image: string): boolean;
    dockerPull(image: string, opts?: {
        onLog?: LogSink;
        timeoutMs?: number;
        signal?: AbortSignal;
    }): Promise<void>;
    dockerVerify(image: string, opts?: {
        onLog?: LogSink;
        timeoutMs?: number;
        signal?: AbortSignal;
    }): Promise<{
        ok: boolean;
        failures: string[];
    }>;
    restoreSnapshot(snapshotPath: string, opts?: {
        onLog?: LogSink;
        timeoutMs?: number;
        signal?: AbortSignal;
    }): Promise<void>;
    /** Full environment health report. */
    status(manifest?: PackageManifest): Promise<RuntimeStatus>;
}
