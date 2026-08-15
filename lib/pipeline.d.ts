import { type LogSink, type Runtime } from './runtime.js';
export declare const packageDir: string;
export interface Comparison {
    control: string | string[];
    treatment: string | string[];
    name: string;
    fc_threshold?: number;
    p_threshold?: number;
}
export interface PipelineParams {
    naThreshold?: number | [number, number];
    normalizationMethod?: 'global' | 'within_group';
    useCommonProteins?: boolean;
    imputationMethod?: 'auto' | 'knn' | 'perseus';
    fcThresholdMode?: 'auto' | 'global' | 'per_comparison';
    globalFcThreshold?: number;
    pThresholdMode?: 'global' | 'per_comparison';
    globalPThreshold?: number;
}
export interface ProjectState {
    created: string;
    organism: string;
    organismName?: string;
    comparisons: Comparison[] | null;
    params: PipelineParams;
    backgrounds: {
        go?: string;
        kegg?: string;
    };
}
/** Escape content for an ALREADY-QUOTED template placeholder (no quotes added). */
export declare function rEscape(value: unknown): string;
/** Full R string literal, including the surrounding quotes. */
export declare function rString(value: unknown): string;
export declare function rLogical(value: unknown): string;
export declare function rNumber(value: unknown): string;
export declare function rVector(values: string[]): string;
export declare function rNaThreshold(value: PipelineParams['naThreshold']): string;
export declare function rComparisons(comparisons: Comparison[] | null): string;
export type CsvRow = Record<string, string>;
export declare function parseCsv(text: string): CsvRow[];
export interface NormalizationSummary {
    retainedProteins: number;
    samples: number;
    imputedByKnn: number;
    imputedByPerseus: number;
    filteredOut: number;
    reportFile: string;
    abundanceFile: string;
}
export interface PcaSummary {
    pc1: number | null;
    pc2: number | null;
    pc3: number | null;
    biplot: string;
    varianceFile: string;
    scoresFile: string;
}
export interface BatchSummary {
    performed: boolean;
    batches: string[];
    pcaAfter: string;
}
export interface DeaProtein {
    accession: string;
    gene: string;
    log2fc: number;
    p: number;
}
export interface DeaComparisonSummary {
    fcThreshold: number | null;
    pThreshold: number | null;
    fcSource: string | null;
    up: number;
    down: number;
    total: number;
    topUp: DeaProtein[];
    topDown: DeaProtein[];
    volcano: string;
}
export interface EnrichmentTerm {
    id: string;
    description: string;
    pAdjust: number | null;
    count: number;
}
export interface EnrichmentComparisonSummary {
    goTerms: number;
    keggPathways: number;
    topGo: EnrichmentTerm[];
    topKegg: EnrichmentTerm[];
}
export interface GseaSet {
    id: string;
    description: string;
    nes: number;
    padj: number;
}
export interface GseaComparisonSummary {
    totalSets: number;
    topPositive: GseaSet[];
    topNegative: GseaSet[];
}
export interface RunStepResult {
    code: number | null;
    timedOut: boolean;
    tail: string;
}
export declare class Project {
    dir: string;
    constructor(projectDir: string);
    static defaultPath(name: string, workspaceRoot?: string): string;
    statePath(): string;
    loadState(): ProjectState | null;
    saveState(state: ProjectState): ProjectState;
    /** Create the project: copy inputs, copy pipeline scripts, generate main.R. */
    create(opts: {
        proteinFile: string;
        sampleInfoFile?: string | null;
        organism: string;
        organismName?: string;
        comparisons: Comparison[] | null;
        params?: PipelineParams;
        backgrounds?: {
            go?: string;
            kegg?: string;
        };
    }): Promise<ProjectState>;
    /** Regenerate main.R from the current state (idempotent; safe to re-run). */
    regenerateMainR(state: ProjectState): string;
    /**
     * Run one pipeline step non-interactively. Streams R output to onLog.
     * backend 'docker' runs the project's own run.R inside a container that
     * mounts this project directory at /workspace (see docker/Dockerfile);
     * the default 'local' backend uses the managed Rscript.
     */
    runStep(runtime: Runtime, step: string, opts?: {
        rerun?: boolean;
        timeoutMs?: number;
        onLog?: LogSink;
        backend?: string;
        dockerImage?: string;
    }): Promise<RunStepResult>;
    resDir(): string;
    summarizeNormalization(): Promise<NormalizationSummary>;
    summarizePca(): Promise<PcaSummary>;
    comparisonDirs(): Promise<string[]>;
    summarizeBatch(): Promise<BatchSummary>;
    summarizeDea(): Promise<Record<string, DeaComparisonSummary>>;
    summarizeEnrichment(): Promise<Record<string, EnrichmentComparisonSummary>>;
    summarizeGsea(): Promise<Record<string, GseaComparisonSummary>>;
    status(): Promise<{
        normalization: boolean;
        pca: boolean;
        batch: boolean;
        dea: string[];
        enrichment: boolean;
        gsea: boolean;
    }>;
}
export interface PreflightResult {
    nProteins: number;
    nSamples: number;
    sampleColumns: string[];
    metaColumns: string[];
    /** Non-meta columns whose values are mostly non-numeric (e.g. MaxQuant "Reverse" flags). */
    nonNumericSampleColumns: string[];
    inferredGroups: string[];
    duplicateAccessions: number;
    naBuckets: {
        none: number;
        low: number;
        mid: number;
        high: number;
    };
    batchColumn: boolean;
    sampleInfo: {
        columns: string[];
        samples: number;
    } | null;
    sampleInfoValid: boolean;
    missingSamples: string[];
    recommendation: string;
}
export declare function preflight(proteinFile: string, sampleInfoFile: string | null): Promise<PreflightResult>;
/** Write a generated sample_info.txt (inferred groups) into the project data dir. */
export declare function writeGeneratedSampleInfo(projectDir: string, sampleColumns: string[], groupOverrides?: Record<string, string> | null): Promise<void>;
