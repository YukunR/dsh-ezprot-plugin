import type { LogSink } from './types.js';
export declare function dockerAvailable(): boolean;
export declare function dockerImageReady(image: string): boolean;
export interface DockerRunResult {
    code: number | null;
    timedOut: boolean;
    tail: string;
}
/**
 * Run a command inside the image: `docker run --rm <dockerArgs> <image> <cmd...>`.
 * dockerArgs must be pre-validated (mount flags etc.); cmd is argv, never shell.
 */
export declare function dockerRun(image: string, dockerArgs: string[], cmd: string[], opts?: {
    onLog?: LogSink;
    timeoutMs?: number;
    signal?: AbortSignal;
}): Promise<DockerRunResult>;
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
