import type { LogSink, RuntimePaths } from './types.js';
export declare function restoreSnapshot(ctx: RuntimePaths, snapshotPath: string, opts?: {
    onLog?: LogSink;
    timeoutMs?: number;
    signal?: AbortSignal;
}): Promise<void>;
