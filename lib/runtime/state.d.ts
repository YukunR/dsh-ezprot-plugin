export interface RuntimeState {
    backend?: 'local' | 'docker';
    dockerImage?: string;
}
export declare class StateStore {
    private dataDir;
    private queue;
    constructor(dataDir: string);
    path(): string;
    get(): Promise<RuntimeState>;
    set(patch: RuntimeState): Promise<void>;
}
