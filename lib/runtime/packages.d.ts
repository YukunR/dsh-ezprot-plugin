import type { LogSink, PackageManifest, RuntimePaths } from './types.js';
export interface PackagesContext extends RuntimePaths {
}
/** Names of packages currently installed in the managed library. */
export declare function installedPackages(ctx: PackagesContext, rscript: string): Promise<string[]>;
/** Install every manifest package that is missing from the managed library. */
export declare function installPackages(ctx: PackagesContext, rscript: string, manifest: PackageManifest, opts?: {
    onLog?: LogSink;
    timeoutMs?: number;
    signal?: AbortSignal;
}): Promise<void>;
/** Missing manifest packages (empty = complete library). */
export declare function missingPackages(ctx: PackagesContext, rscript: string, manifest: PackageManifest): Promise<string[]>;
/**
 * Runtime capability probe: loads every manifest package and exercises the
 * heavy pipeline code paths (PCAtools encircle/ggalt, ComBat, enricher).
 * Catches Suggests-only gaps that static manifest checks cannot see.
 */
export declare function verifyRuntime(ctx: PackagesContext, rscript: string, manifest: PackageManifest, opts?: {
    onLog?: LogSink;
    timeoutMs?: number;
    signal?: AbortSignal;
}): Promise<{
    ok: boolean;
    failures: string[];
    tail: string;
}>;
