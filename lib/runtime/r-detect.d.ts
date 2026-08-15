import type { LogSink, RuntimePaths } from './types.js';
export interface RDetectContext extends RuntimePaths {
    /** Explicit rscript override from the plugin config. */
    rscript?: string;
}
/** R version string like "4.4", or null when the executable is not R. */
export declare function rVersion(rscript: string): string | null;
/** Locate a usable Rscript (config override → plugin-managed → common dirs → PATH). */
export declare function detectRscript(ctx: RDetectContext): Promise<string | null>;
/** Download and silently install the pinned R version into the managed dir (no admin). */
export declare function installR(ctx: RDetectContext, opts?: {
    onLog?: LogSink;
    signal?: AbortSignal;
}): Promise<string>;
