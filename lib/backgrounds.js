// Annotation background management: per-organism GO/KEGG background cache.
// Every organism (human/mouse/rat) is built once on demand from KEGG REST +
// UniProt and then reused forever; no backgrounds ship with the plugin.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { downloadFile } from './runtime.js';
export const packageDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const ORGANISMS = {
    human: { name: 'Homo sapiens', kegg: 'hsa', taxon: 9606 },
    mouse: { name: 'Mus musculus', kegg: 'mmu', taxon: 10090 },
    rat: { name: 'Rattus norvegicus', kegg: 'rno', taxon: 10116 },
};
/** Run an R script with the managed library, streaming output to onLog. */
export function runRscript(runtime, args, opts = {}) {
    return new Promise((resolvePromise, reject) => {
        const log = opts.onLog ?? (() => { });
        const timeoutMs = opts.timeoutMs ?? 30 * 60 * 1000;
        runtime.detectRscript().then((exe) => {
            if (!exe) {
                reject(new Error('no R installation found; run proteomics_environment with action=setup first'));
                return;
            }
            mkdirSync(runtime.libraryDir, { recursive: true });
            const proc = spawn(exe, args, {
                cwd: opts.cwd ?? runtime.dataDir,
                env: { ...process.env, R_LIBS_USER: runtime.libraryDir },
                windowsHide: true,
            });
            let tail = '';
            let tailFull = '';
            const push = (text) => {
                tailFull += text;
                tail = tailFull.length > 6000 ? tailFull.slice(-6000) : tailFull;
                log(text);
            };
            proc.stdout.on('data', (d) => push(d.toString()));
            proc.stderr.on('data', (d) => push(d.toString()));
            let timedOut = false;
            const timer = setTimeout(() => {
                timedOut = true;
                try {
                    proc.kill();
                }
                catch { /* already dead */ }
            }, timeoutMs);
            proc.on('error', (error) => {
                clearTimeout(timer);
                reject(error);
            });
            proc.on('close', (code) => {
                clearTimeout(timer);
                resolvePromise({ code, timedOut, tail });
            });
        }, reject);
    });
}
export class Backgrounds {
    runtime;
    cacheDir;
    enableNetwork;
    constructor(runtime, config = {}) {
        this.runtime = runtime;
        this.cacheDir = join(runtime.dataDir, 'backgrounds');
        this.enableNetwork = config.enableNetwork !== false;
    }
    goPath(organism) {
        return join(this.cacheDir, organism, 'go_background.csv');
    }
    keggPath(organism) {
        return join(this.cacheDir, organism, 'kegg_background.txt');
    }
    status(organism) {
        return {
            organism,
            go: existsSync(this.goPath(organism)),
            kegg: existsSync(this.keggPath(organism)),
            cacheDir: join(this.cacheDir, organism),
        };
    }
    /**
     * Make both backgrounds available for the organism: reuse the cache,
     * otherwise build from the network (once per organism).
     */
    async ensure(organism, opts = {}) {
        const log = opts.onLog ?? (() => { });
        if (!ORGANISMS[organism])
            throw new Error(`unknown organism '${organism}' (supported: ${Object.keys(ORGANISMS).join(', ')})`);
        mkdirSync(join(this.cacheDir, organism), { recursive: true });
        const needKegg = !existsSync(this.keggPath(organism));
        const needGo = !existsSync(this.goPath(organism));
        if (needKegg) {
            if (!this.enableNetwork)
                throw new Error(`KEGG background missing for ${organism} and network building is disabled`);
            await this.buildKegg(organism, { onLog: log });
        }
        if (needGo) {
            if (!this.enableNetwork)
                throw new Error(`GO background missing for ${organism} and network building is disabled`);
            await this.buildGo(organism, { onLog: log });
        }
        return { go: this.goPath(organism), kegg: this.keggPath(organism) };
    }
    async buildKegg(organism, opts = {}) {
        const log = opts.onLog ?? (() => { });
        const org = ORGANISMS[organism];
        const output = this.keggPath(organism);
        log(`building KEGG background for ${organism} (${org.name}, ${org.kegg}) — downloads from KEGG REST + UniProt, takes 2–5 min ...`);
        const res = await runRscript(this.runtime, [
            join(packageDir, 'r', 'background', 'build_kegg_background.R'),
            '--kegg-code', org.kegg,
            '--species-name', org.name,
            '--uniprot-taxon', String(org.taxon),
            '--output', output,
        ], { onLog: log, timeoutMs: 20 * 60 * 1000 });
        if (res.timedOut)
            throw new Error(`KEGG background build timed out for ${organism}`);
        if (res.code !== 0 || !existsSync(output)) {
            throw new Error(`KEGG background build failed for ${organism} (exit ${res.code})\n${res.tail.slice(-3000)}`);
        }
        log(`KEGG background ready: ${output}`);
    }
    async buildGo(organism, opts = {}) {
        const log = opts.onLog ?? (() => { });
        const org = ORGANISMS[organism];
        const tsv = join(this.cacheDir, organism, `uniprot_${org.taxon}_go.tsv`);
        const output = this.goPath(organism);
        log(`downloading UniProt GO annotations for ${organism} (taxon ${org.taxon}) ...`);
        const url = 'https://rest.uniprot.org/uniprotkb/stream?compressed=false&fields=accession%2Cid%2Cgene_names%2Cgo_id%2Cgo&format=tsv&query=%28*%29+AND+%28model_organism%3A' + org.taxon + '%29+AND+%28reviewed%3Atrue%29';
        await downloadFile(url, tsv, { retries: 2, timeoutMs: 20 * 60 * 1000 });
        log(`building GO background for ${organism} from ${tsv} ...`);
        const res = await runRscript(this.runtime, [
            join(packageDir, 'r', 'background', 'build_go_background.R'),
            '--method', 'uniprot',
            '--uniprot-file', tsv,
            '--output', output,
        ], { onLog: log, timeoutMs: 20 * 60 * 1000 });
        if (res.timedOut)
            throw new Error(`GO background build timed out for ${organism}`);
        if (res.code !== 0 || !existsSync(output)) {
            throw new Error(`GO background build failed for ${organism} (exit ${res.code})\n${res.tail.slice(-3000)}`);
        }
        log(`GO background ready: ${output}`);
    }
}
