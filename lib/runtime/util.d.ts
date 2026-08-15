import { type ChildProcess } from 'node:child_process';
export declare function sleep(ms: number): Promise<void>;
/** Kill a spawned process when the signal aborts (no-op without a signal). */
export declare function wireKillOnAbort(proc: ChildProcess, signal?: AbortSignal): void;
/** Download with redirects, retries, and a per-attempt timeout. Returns the destination path. */
export declare function downloadFile(url: string, dest: string, opts?: {
    retries?: number;
    timeoutMs?: number;
}): Promise<string>;
/** Prefer R 4.4.x; accept R >= 4.4; reject older. Returns a numeric score. */
export declare function versionScore(major: number, minor: number): number;
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
/** Run `command --version`-style spawn and return the trimmed first line. */
export declare function spawnString(cmd: string, args: string[], timeoutMs: number): string | null;
