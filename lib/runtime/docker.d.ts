import type { LogSink } from './types.js';
export declare function dockerAvailable(): boolean;
export declare function dockerImageReady(image: string): boolean;
export declare function dockerPull(image: string, opts?: {
    onLog?: LogSink;
    timeoutMs?: number;
    signal?: AbortSignal;
}): Promise<void>;
/** Run the runtime probe INSIDE the image (the image carries check_runtime.R). */
export declare function dockerVerify(image: string, opts?: {
    onLog?: LogSink;
    timeoutMs?: number;
    signal?: AbortSignal;
}): Promise<{
    ok: boolean;
    failures: string[];
}>;
