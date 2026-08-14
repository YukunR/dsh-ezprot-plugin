import type { Runtime } from './runtime.js';
export type ColumnRole = 'id' | 'gene' | 'desc' | 'sample' | 'annotation' | 'unknown';
export interface ColumnClass {
    name: string;
    role: ColumnRole;
    reason: string;
    numericRatio: number | null;
}
export interface InspectResult {
    file: string;
    convertedFrom: string | null;
    sheets: string[];
    columns: ColumnClass[];
    nRows: number;
    preview: string[][];
    missing: {
        nan: number;
        blank: number;
        zero: number;
    };
    inferredGroups: string[];
}
interface ParsedTable {
    header: string[];
    rows: string[][];
    missing: {
        nan: number;
        blank: number;
        zero: number;
    };
}
/** Parse a TSV/CSV into header + rows (values left as strings). */
export declare function parseTable(text: string, sep?: string): ParsedTable;
/** Classify every column of a raw table with heuristics (candidates only — the user confirms). */
export declare function classifyColumns(header: string[], rows: string[][]): ColumnClass[];
export declare function inferGroupNames(sampleNames: string[]): string[];
/** Inspect a raw file: convert Excel to TSV when needed, classify, preview. */
export declare function inspectRawFile(inputFile: string, runtime: Runtime, opts?: {
    sheet?: string;
}): Promise<InspectResult>;
export interface TidyOptions {
    idColumn: string;
    geneColumn?: string;
    descColumn?: string;
    sampleColumns: string[];
    groupMapping?: Record<string, string>;
    missingZero?: boolean;
    sheet?: string;
}
export interface TidyResult {
    proteinFile: string;
    sampleInfoFile: string;
    keptRows: number;
    droppedRows: number;
    duplicateAccessions: number;
    groups: string[];
}
/** Tidy a raw file into origin_data.txt + sample_info.txt under outputDir. */
export declare function tidyRawFile(inputFile: string, runtime: Runtime, outputDir: string, opts: TidyOptions): Promise<TidyResult>;
export {};
