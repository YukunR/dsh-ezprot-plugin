// Persisted runtime state (backend choice + image). Writes are atomic and
// serialized so concurrent callers cannot lose fields or observe torn JSON.
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
export class StateStore {
    dataDir;
    queue = Promise.resolve();
    constructor(dataDir) {
        this.dataDir = dataDir;
    }
    path() {
        return join(this.dataDir, 'runtime-state.json');
    }
    async get() {
        try {
            const raw = await readFile(this.path(), 'utf8');
            const parsed = JSON.parse(raw);
            return {
                backend: parsed.backend === 'docker' || parsed.backend === 'local' ? parsed.backend : undefined,
                dockerImage: typeof parsed.dockerImage === 'string' ? parsed.dockerImage : undefined,
            };
        }
        catch {
            return {};
        }
    }
    async set(patch) {
        const run = this.queue.then(async () => {
            await mkdir(this.dataDir, { recursive: true });
            const current = await this.get();
            // write-then-rename: readers (get) never observe a torn file
            const tmp = `${this.path()}.tmp`;
            await writeFile(tmp, JSON.stringify({ ...current, ...patch }, null, 2), 'utf8');
            await rename(tmp, this.path());
        });
        this.queue = run.catch(() => { });
        await run;
    }
}
