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
    shippedGo: boolean;
    shippedKegg: boolean;
    cacheDir: string;
}
export declare class Backgrounds {
    runtime: Runtime;
    cacheDir: string;
    shippedDir: string;
    enableNetwork: boolean;
    constructor(runtime: Runtime, config?: {
        enableNetwork?: boolean;
    });
    goPath(organism: Organism): string;
    keggPath(organism: Organism): string;
    status(organism: Organism): BackgroundStatus;
    /**
     * Make both backgrounds available for the organism: prefer shipped files,
     * then cache; otherwise build from the network (once per organism).
     */
    ensure(organism: Organism, opts?: {
        onLog?: LogSink;
    }): Promise<{
        go: string;
        kegg: string;
    }>;
    buildKegg(organism: Organism, opts?: {
        onLog?: LogSink;
    }): Promise<void>;
    buildGo(organism: Organism, opts?: {
        onLog?: LogSink;
    }): Promise<void>;
}
