// Annotation background management: per-organism GO/KEGG background cache.
// Every organism (human/mouse/rat) is built once on demand from KEGG REST +
// UniProt and then reused forever; no backgrounds ship with the plugin.
// Builds run with local R, or inside the ezprot Docker image (backend=docker)
// so sandboxed host processes with no TLS/network access can still build.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DEFAULT_DOCKER_IMAGE, downloadFile, dockerRun } from './runtime.js';
import { toContainerPath, toHostPath } from './pipeline.js';
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
     * otherwise build from the network (once per organism). backend 'docker'
     * builds inside the ezprot image, which works even when the host process
     * runs in a network-restricted sandbox.
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
            await this.buildKegg(organism, opts);
        }
        if (needGo) {
            if (!this.enableNetwork)
                throw new Error(`GO background missing for ${organism} and network building is disabled`);
            await this.buildGo(organism, opts);
        }
        return { go: this.goPath(organism), kegg: this.keggPath(organism) };
    }
    async buildKegg(organism, opts = {}) {
        const log = opts.onLog ?? (() => { });
        const org = ORGANISMS[organism];
        const output = this.keggPath(organism);
        log(`building KEGG background for ${organism} (${org.name}, ${org.kegg}) — downloads from KEGG REST + UniProt, takes 2–5 min ...`);
        const args = [
            backgroundScriptPath('build_kegg_background.R', opts.backend ?? 'local'),
            '--kegg-code', org.kegg,
            '--species-name', org.name,
            '--uniprot-taxon', String(org.taxon),
            '--output', opts.backend === 'docker' ? toContainerPath(output) : output,
        ];
        const res = opts.backend === 'docker'
            ? await this.runInDocker(opts.dockerImage, args, { onLog: log, signal: opts.signal })
            : await runRscript(this.runtime, args, { onLog: log, timeoutMs: 20 * 60 * 1000 });
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
        const url = 'https://rest.uniprot.org/uniprotkb/stream?compressed=false&fields=accession%2Cid%2Cgene_names%2Cgo_id%2Cgo&format=tsv&query=%28*%29+AND+%28model_organism%3A' + org.taxon + '%29+AND+%28reviewed%3Atrue%29';
        if (opts.backend === 'docker') {
            // The container has network access even when the host process is
            // sandboxed: download the UniProt stream and build in two in-image
            // steps, with every path expressed as its container-internal form.
            const tsvContainer = toContainerPath(tsv);
            const outContainer = toContainerPath(output);
            log(`downloading UniProt GO annotations for ${organism} inside the docker image ...`);
            const dl = await this.runInDocker(opts.dockerImage, [
                '-e', rDownloadCommand(url, tsvContainer),
            ], { onLog: log, signal: opts.signal });
            if (dl.timedOut)
                throw new Error(`GO background download timed out for ${organism}`);
            if (dl.code !== 0)
                throw new Error(`GO background download failed for ${organism} (exit ${dl.code})\n${dl.tail.slice(-3000)}`);
            log(`building GO background for ${organism} inside the docker image ...`);
            const res = await this.runInDocker(opts.dockerImage, [
                backgroundScriptPath('build_go_background.R', 'docker'),
                '--method', 'uniprot',
                '--uniprot-file', tsvContainer,
                '--output', outContainer,
            ], { onLog: log, signal: opts.signal });
            if (res.timedOut)
                throw new Error(`GO background build timed out for ${organism}`);
            if (res.code !== 0 || !existsSync(output)) {
                throw new Error(`GO background build failed for ${organism} (exit ${res.code})\n${res.tail.slice(-3000)}`);
            }
            log(`GO background ready: ${output}`);
            return;
        }
        log(`downloading UniProt GO annotations for ${organism} (taxon ${org.taxon}) ...`);
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
    /**
     * Run a background script inside the ezprot image: bind-mount the shipped
     * background scripts (read-only usage) and the organism cache dir (mapped to
     * its drive-less host path, matching toContainerPath).
     */
    async runInDocker(dockerImage, rscriptArgs, opts = {}) {
        const image = dockerImage ?? DEFAULT_DOCKER_IMAGE;
        const scripts = toHostPath(join(packageDir, 'r', 'background'));
        const cache = toHostPath(this.cacheDir);
        return dockerRun(image, [
            '--mount', `type=bind,source=${scripts},target=/opt/ezprot-bg`,
            '--mount', `type=bind,source=${cache},target=${toContainerPath(cache)}`,
        ], ['Rscript', ...rscriptArgs], {
            onLog: opts.onLog,
            timeoutMs: 20 * 60 * 1000,
            signal: opts.signal,
        });
    }
}
/** R expression that downloads `url` to `dest` inside the container. */
export function rDownloadCommand(url, dest) {
    // Single-quoted R string literals: both inputs carry no single quotes by
    // construction (URL constant, container path), and paths with spaces are
    // fine inside quotes.
    return `options(timeout=900); download.file('${url}', '${dest}', mode='wb')`;
}
/**
 * Script path for a background build: host path for local R, container path
 * (/opt/ezprot-bg, where runInDocker bind-mounts the scripts dir) for docker.
 */
export function backgroundScriptPath(name, backend) {
    return backend === 'docker'
        ? `/opt/ezprot-bg/${name}`
        : join(packageDir, 'r', 'background', name);
}
