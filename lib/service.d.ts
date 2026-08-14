import { Runtime, type LogSink, type PackageManifest, type RuntimeStatus } from './runtime.js';
import { Backgrounds, type BackgroundStatus, type Organism } from './backgrounds.js';
import { Project, type Comparison, type PipelineParams, type ProjectState } from './pipeline.js';
export declare const STEPS: readonly ["normalization", "pca", "batch_remove", "dea", "enrich", "gsea", "all"];
export type Step = (typeof STEPS)[number];
export interface ServiceConfig {
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
export interface EnvironmentReport extends RuntimeStatus {
    dockerAvailable: boolean;
    dockerImage: string;
    organisms: Record<string, BackgroundStatus>;
    dataDir: string;
}
export interface StepSummaryMap {
    normalization?: ReturnType<Project['summarizeNormalization']> extends Promise<infer T> ? T : never;
    pca?: ReturnType<Project['summarizePca']> extends Promise<infer T> ? T : never;
    batch?: ReturnType<Project['summarizeBatch']> extends Promise<infer T> ? T : never;
    dea?: ReturnType<Project['summarizeDea']> extends Promise<infer T> ? T : never;
    enrichment?: ReturnType<Project['summarizeEnrichment']> extends Promise<infer T> ? T : never;
    gsea?: ReturnType<Project['summarizeGsea']> extends Promise<infer T> ? T : never;
}
export declare class ProteomicsService {
    config: ServiceConfig;
    runtime: Runtime;
    backgrounds: Backgrounds;
    private manifestPromise;
    private locks;
    timeoutMs: number;
    constructor(config?: ServiceConfig);
    loadManifest(): Promise<PackageManifest>;
    withLock<T>(key: string, fn: () => Promise<T>): Promise<T>;
    dockerAvailable(): Promise<boolean>;
    environmentStatus(): Promise<EnvironmentReport>;
    environmentSetup(opts?: {
        action?: 'status' | 'setup' | 'restore_snapshot';
        snapshotPath?: string;
        onLog?: LogSink;
    }): Promise<EnvironmentReport>;
    backgroundEnsure(organism: Organism, opts?: {
        onLog?: LogSink;
    }): Promise<{
        go: string;
        kegg: string;
    }>;
    preflightProject(opts: {
        projectDir: string;
        proteinFile: string;
        sampleInfoFile?: string | null;
        organism: Organism;
        organismName?: string;
        comparisons?: Comparison[] | null;
        params?: PipelineParams;
    }): Promise<string>;
    /** backend: 'auto' → docker only when no local R exists but Docker does. */
    resolveBackend(hasLocalR: boolean, hasDocker: boolean): 'local' | 'docker';
    runStep(opts: {
        projectDir: string;
        step: Step;
        rerun?: boolean;
        params?: PipelineParams;
        onLog?: LogSink;
    }): Promise<string>;
    stepSummary(project: Project, step: Step, _state: ProjectState): Promise<StepSummaryMap>;
    formatSummary(step: Step, summary: StepSummaryMap): string[];
    report(projectDir: string): Promise<string>;
}
