// Managed package library: probe installed packages, install the manifest
// into the managed library, and run the deep runtime capability probe.
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { BIOC_VERSION, checkScriptPath, installScriptPath, LINUX_BINARY_CRAN } from './constants.js';
import { wireKillOnAbort } from './util.js';
function runtimeManifest(ctx, manifest) {
    return {
        cran: manifest.cran,
        bioc: manifest.bioc,
        biocVersion: BIOC_VERSION,
        repos: { cran: ctx.cranRepo, bioc: ctx.biocRepo, linuxBinaryCran: LINUX_BINARY_CRAN },
    };
}
/** Names of packages currently installed in the managed library. */
export function installedPackages(ctx, rscript) {
    return new Promise((resolvePromise, reject) => {
        mkdirSync(ctx.libraryDir, { recursive: true });
        const proc = spawn(rscript, ['-e', 'cat(paste(rownames(installed.packages()), collapse="\\n"))'], {
            env: { ...process.env, R_LIBS_USER: ctx.libraryDir },
            windowsHide: true,
        });
        let out = '';
        let err = '';
        proc.stdout.on('data', (d) => (out += d));
        proc.stderr.on('data', (d) => (err += d));
        proc.on('error', reject);
        proc.on('close', (code) => {
            if (code !== 0)
                reject(new Error(`installed.packages() failed (exit ${code}): ${err.slice(0, 2000)}`));
            else
                resolvePromise(out.split(/\r?\n/).map((s) => s.trim()).filter(Boolean));
        });
    });
}
/** Install every manifest package that is missing from the managed library. */
export async function installPackages(ctx, rscript, manifest, opts = {}) {
    const log = opts.onLog ?? (() => { });
    const timeoutMs = opts.timeoutMs ?? 45 * 60 * 1000;
    mkdirSync(ctx.libraryDir, { recursive: true });
    await writeFile(join(ctx.dataDir, 'manifest-runtime.json'), JSON.stringify(runtimeManifest(ctx, manifest)));
    // NOTE: Rscript takes the script path as a plain positional argument;
    // `--file=` is an R (CMD BATCH) flag that Rscript does NOT interpret as
    // the script selector, so passing it here made Rscript parse the JSON
    // manifest as the script (caught by the fresh-machine test).
    const proc = spawn(rscript, [installScriptPath(), join(ctx.dataDir, 'manifest-runtime.json')], {
        cwd: ctx.dataDir,
        env: { ...process.env, R_LIBS_USER: ctx.libraryDir },
        windowsHide: true,
    });
    wireKillOnAbort(proc, opts.signal);
    let out = '';
    let err = '';
    proc.stdout.on('data', (d) => { out += d; log(d); });
    proc.stderr.on('data', (d) => { err += d; log(d); });
    const timedOut = await new Promise((resolvePromise) => {
        const timer = setTimeout(() => {
            try {
                proc.kill();
            }
            catch { /* already dead */ }
            resolvePromise(true);
        }, timeoutMs);
        proc.on('error', () => { clearTimeout(timer); resolvePromise(false); });
        proc.on('close', () => { clearTimeout(timer); resolvePromise(false); });
    });
    const stillMissingMatch = /STILL_MISSING:[^\r\n]*/.exec(out);
    if (timedOut)
        throw new Error(`package installation timed out after ${timeoutMs}ms`);
    if (stillMissingMatch) {
        const listed = stillMissingMatch[0].replace(/^STILL_MISSING:\s*/, '').trim();
        if (listed !== '') {
            throw new Error(`these packages are still missing after installation: ${listed}\n${err.slice(-4000)}`);
        }
    }
    const allOk = /ALL_PACKAGES_OK/.test(out);
    if (!allOk)
        throw new Error(`package installation did not finish successfully\n${(err || out).slice(-4000)}`);
    log('All required R packages are installed.');
}
/** Missing manifest packages (empty = complete library). */
export async function missingPackages(ctx, rscript, manifest) {
    const installed = await installedPackages(ctx, rscript);
    const required = [...(manifest.cran ?? []), ...(manifest.bioc ?? [])];
    return required.filter((pkg) => !installed.includes(pkg));
}
/**
 * Runtime capability probe: loads every manifest package and exercises the
 * heavy pipeline code paths (PCAtools encircle/ggalt, ComBat, enricher).
 * Catches Suggests-only gaps that static manifest checks cannot see.
 */
export async function verifyRuntime(ctx, rscript, manifest, opts = {}) {
    const log = opts.onLog ?? (() => { });
    const timeoutMs = opts.timeoutMs ?? 15 * 60 * 1000;
    await writeFile(join(ctx.dataDir, 'manifest-runtime.json'), JSON.stringify(runtimeManifest(ctx, manifest)));
    const proc = spawn(rscript, [checkScriptPath(), join(ctx.dataDir, 'manifest-runtime.json')], {
        cwd: ctx.dataDir,
        env: { ...process.env, R_LIBS_USER: ctx.libraryDir },
        windowsHide: true,
    });
    wireKillOnAbort(proc, opts.signal);
    let out = '';
    let err = '';
    proc.stdout.on('data', (d) => { out += d; log(d); });
    proc.stderr.on('data', (d) => { err += d; log(d); });
    let timedOut = false;
    const code = await new Promise((resolvePromise) => {
        const timer = setTimeout(() => {
            timedOut = true;
            try {
                proc.kill();
            }
            catch { /* already dead */ }
        }, timeoutMs);
        proc.on('error', () => { clearTimeout(timer); resolvePromise(null); });
        proc.on('close', (c) => { clearTimeout(timer); resolvePromise(c); });
    });
    const failures = [...out.matchAll(/CHECK_FAIL:\s*([^\r\n]*)/g)].map((m) => m[1].trim());
    if (code !== 0 && failures.length === 0) {
        failures.push(`probe exited with code ${code}`);
    }
    return {
        ok: !timedOut && code === 0 && failures.length === 0,
        failures,
        tail: (err || out).slice(-3000),
    };
}
