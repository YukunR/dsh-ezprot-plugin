import { type LogSink, type Runtime } from './runtime.js';
export declare const packageDir: string;
export type Organism = 'human' | 'mouse' | 'rat';
export interface OrganismInfo {
    name: string;
    kegg: string;
    taxon: number;
}
export declare const ORGANISMS: Record<Organism, OrganismInfo>;
export interface RRunResult {
    code: number | null;
    timedOut: boolean;
    tail: string;
}
export interface BackgroundBuildOptions {
    onLog?: LogSink;
    /** 'docker' runs the build inside the ezprot image (host-sandbox safe). */
    backend?: 'local' | 'docker';
    dockerImage?: string;
    signal?: AbortSignal;
}
/** Run an R script with the managed library, streaming output to onLog. */
export declare function runRscript(runtime: Runtime, args: string[], opts?: {
    cwd?: string;
    onLog?: LogSink;
    timeoutMs?: number;
}): Promise<RRunResult>;
export interface BackgroundStatus {
    organism: string;
    go: boolean;
    kegg: boolean;
    cacheDir: string;
}
export declare class Backgrounds {
    runtime: Runtime;
    cacheDir: string;
    enableNetwork: boolean;
    constructor(runtime: Runtime, config?: {
        enableNetwork?: boolean;
    });
    goPath(organism: Organism): string;
    keggPath(organism: Organism): string;
    status(organism: Organism): BackgroundStatus;
    /**
     * Make both backgrounds available for the organism: reuse the cache,
     * otherwise build from the network (once per organism). backend 'docker'
     * builds inside the ezprot image, which works even when the host process
     * runs in a network-restricted sandbox.
     */
    ensure(organism: Organism, opts?: BackgroundBuildOptions): Promise<{
        go: string;
        kegg: string;
    }>;
    buildKegg(organism: Organism, opts?: BackgroundBuildOptions): Promise<void>;
    buildGo(organism: Organism, opts?: BackgroundBuildOptions): Promise<void>;
    /**
     * Run a background script inside the ezprot image: bind-mount the shipped
     * background scripts (read-only usage) and the organism cache dir (mapped to
     * its drive-less host path, matching toContainerPath).
     */
    private runInDocker;
}
/** R expression that downloads `url` to `dest` inside the container. */
export declare function rDownloadCommand(url: string, dest: string): string;
