// Raw data import: inspect messy TSV/CSV/Excel files from biologists,
// classify columns with heuristics, and tidy them into the pipeline's
// canonical format (Accession, GeneName, Description + sample columns).
import { existsSync, mkdirSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { packageDir, runRscript } from './backgrounds.js';
const IS_XLSX = /\.xlsx?$/i;
const UNIPROT_PATTERN = /^[OPQ][0-9][A-Z0-9]{3}[0-9]$|^[A-NR-Z][0-9]([A-Z][A-Z0-9]{2}[0-9])?[A-Z0-9]?$/;
const ID_HEADER = /accession|uniprot|entry|protein\s*id|protein\s*group|majority|proteins?$/i;
const GENE_HEADER = /gene|symbol/i;
const DESC_HEADER = /description|protein\s*name|full\s*name|title|fasta/i;
const ANNOTATION_HEADER = /molecular|mass|m\.?w\.?|kda|coverage|psm|peptide\s*count|razor|unique\s*peptide|score|q-?value|p-?value|fdr|sequence|modif|charge|missed|localiz|ambiguity|intensity\s*rank|top\s*\d/i;
const SAMPLE_HEADER = /intensity|abundance|lfq|tmt|itraq|reporter\s*quant/i;
/** Parse a TSV/CSV into header + rows (values left as strings). */
export function parseTable(text, sep = '\t') {
    const lines = text.split(/\r?\n/);
    if (lines.length === 0)
        return { header: [], rows: [], missing: { nan: 0, blank: 0, zero: 0 } };
    const header = lines[0].split(sep);
    const rows = [];
    const missing = { nan: 0, blank: 0, zero: 0 };
    for (const line of lines.slice(1)) {
        if (line.trim() === '')
            continue;
        const cells = line.split(sep);
        rows.push(cells);
        for (const c of cells) {
            const v = c.trim();
            if (v === '' || v.toLowerCase() === 'na')
                missing.blank++;
            else if (v.toLowerCase() === 'nan')
                missing.nan++;
            else if (v === '0' || v === '0.0')
                missing.zero++;
        }
    }
    return { header, rows, missing };
}
function looksNumeric(values) {
    let numeric = 0;
    let total = 0;
    for (const v of values) {
        const t = v.trim();
        if (t === '' || t.toLowerCase() === 'nan' || t.toLowerCase() === 'na')
            continue;
        total++;
        if (/^[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?$/.test(t))
            numeric++;
    }
    return total === 0 ? 0 : numeric / total;
}
/** Classify every column of a raw table with heuristics (candidates only — the user confirms). */
export function classifyColumns(header, rows) {
    const columnValues = (idx) => rows.slice(0, 300).map((r) => r[idx] ?? '').filter((v) => v !== undefined);
    return header.map((name, idx) => {
        const h = name.trim();
        const values = columnValues(idx);
        const ratio = looksNumeric(values);
        if (ID_HEADER.test(h))
            return { name, role: 'id', reason: 'header matches protein-id vocabulary', numericRatio: ratio };
        if (GENE_HEADER.test(h))
            return { name, role: 'gene', reason: 'header matches gene-symbol vocabulary', numericRatio: ratio };
        if (DESC_HEADER.test(h))
            return { name, role: 'desc', reason: 'header matches description vocabulary', numericRatio: ratio };
        if (ANNOTATION_HEADER.test(h))
            return { name, role: 'annotation', reason: 'header matches quality/annotation vocabulary', numericRatio: ratio };
        if (SAMPLE_HEADER.test(h))
            return { name, role: 'sample', reason: 'header matches quantification vocabulary', numericRatio: ratio };
        if (ratio >= 0.8) {
            return { name, role: 'sample', reason: `numeric column (${(ratio * 100).toFixed(0)}% numeric)`, numericRatio: ratio };
        }
        const idLike = values.slice(0, 200).filter((v) => UNIPROT_PATTERN.test(v.trim())).length;
        if (values.length > 0 && idLike / Math.min(values.length, 200) >= 0.8) {
            return { name, role: 'id', reason: 'values look like UniProt accessions', numericRatio: ratio };
        }
        return { name, role: 'unknown', reason: 'not recognized', numericRatio: ratio };
    });
}
export function inferGroupNames(sampleNames) {
    const infer = (name) => String(name).replace(/[_\-.]\d+$/, '');
    return [...new Set(sampleNames.map(infer))];
}
/** Inspect a raw file: convert Excel to TSV when needed, classify, preview. */
export async function inspectRawFile(inputFile, runtime, opts = {}) {
    if (!existsSync(inputFile))
        throw new Error(`file not found: ${inputFile}`);
    let file = inputFile;
    let convertedFrom = null;
    let sheets = [];
    if (IS_XLSX.test(inputFile)) {
        const importDir = join(runtime.dataDir, 'imports');
        mkdirSync(importDir, { recursive: true });
        const out = join(importDir, `${Date.now()}_sheet.tsv`);
        const res = await runRscript(runtime, [
            join(packageDir, 'r', 'import', 'export_xlsx.R'),
            inputFile,
            out,
            opts.sheet ?? '',
        ], { timeoutMs: 10 * 60 * 1000 });
        if (res.code !== 0 || !existsSync(out)) {
            throw new Error(`Excel conversion failed (exit ${res.code})\n${res.tail.slice(-3000)}`);
        }
        const sheetsMatch = /sheets:\s*([^\n]+)/.exec(res.tail);
        if (sheetsMatch)
            sheets = sheetsMatch[1].split('|').map((s) => s.trim()).filter(Boolean);
        convertedFrom = out;
        file = out;
    }
    const text = await readFile(file, 'utf8');
    const table = parseTable(text);
    const columns = classifyColumns(table.header, table.rows);
    const sampleNames = columns.filter((c) => c.role === 'sample').map((c) => c.name);
    const preview = [table.header, ...table.rows.slice(0, 4)].map((row) => row.map((v) => (v ?? '').slice(0, 24)));
    return {
        file: inputFile,
        convertedFrom,
        sheets,
        columns,
        nRows: table.rows.length,
        preview,
        missing: table.missing,
        inferredGroups: inferGroupNames(sampleNames),
    };
}
/** Tidy a raw file into origin_data.txt + sample_info.txt under outputDir. */
export async function tidyRawFile(inputFile, runtime, outputDir, opts) {
    let file = inputFile;
    if (IS_XLSX.test(inputFile)) {
        const importDir = join(runtime.dataDir, 'imports');
        mkdirSync(importDir, { recursive: true });
        const out = join(importDir, `${Date.now()}_tidy.tsv`);
        const res = await runRscript(runtime, [
            join(packageDir, 'r', 'import', 'export_xlsx.R'),
            inputFile,
            out,
            opts.sheet ?? '',
        ], { timeoutMs: 10 * 60 * 1000 });
        if (res.code !== 0 || !existsSync(out)) {
            throw new Error(`Excel conversion failed (exit ${res.code})\n${res.tail.slice(-3000)}`);
        }
        file = out;
    }
    const text = await readFile(file, 'utf8');
    const table = parseTable(text);
    const header = table.header;
    const idx = (name) => (name === undefined ? -1 : header.indexOf(name));
    const idIdx = idx(opts.idColumn);
    if (idIdx < 0)
        throw new Error(`id column '${opts.idColumn}' not found in header: ${header.join(', ')}`);
    const geneIdx = idx(opts.geneColumn);
    const descIdx = idx(opts.descColumn);
    const sampleIdx = opts.sampleColumns.map((c) => idx(c));
    for (let i = 0; i < sampleIdx.length; i++) {
        if (sampleIdx[i] < 0)
            throw new Error(`sample column '${opts.sampleColumns[i]}' not found in header`);
    }
    const missingZero = opts.missingZero ?? true;
    const infer = (name) => String(name).replace(/[_\-.]\d+$/, '');
    const outHeader = ['Accession', 'GeneName', 'Description', ...opts.sampleColumns];
    const outRows = [];
    const seen = new Set();
    let duplicateAccessions = 0;
    let droppedRows = 0;
    for (const row of table.rows) {
        const acc = (row[idIdx] ?? '').trim();
        if (acc === '') {
            droppedRows++;
            continue;
        }
        if (seen.has(acc))
            duplicateAccessions++;
        seen.add(acc);
        const samples = sampleIdx.map((i) => {
            const v = (row[i] ?? '').trim();
            if (v === '' || v.toLowerCase() === 'nan' || v.toLowerCase() === 'na')
                return 'NaN';
            if (missingZero && (v === '0' || v === '0.0' || v === '-0' || v === '-0.0'))
                return 'NaN';
            return v;
        });
        outRows.push([
            acc,
            geneIdx >= 0 ? (row[geneIdx] ?? '').trim() : '',
            descIdx >= 0 ? (row[descIdx] ?? '').trim() : '',
            ...samples,
        ]);
    }
    if (outRows.length === 0)
        throw new Error('no data rows remained after tidy — check the id column selection');
    mkdirSync(outputDir, { recursive: true });
    const proteinFile = join(outputDir, 'origin_data.txt');
    const sampleInfoFile = join(outputDir, 'sample_info.txt');
    await writeFile(proteinFile, [outHeader.join('\t'), ...outRows.map((r) => r.join('\t'))].join('\n') + '\n', 'utf8');
    const groups = [];
    const infoLines = ['Sample\tGroup'];
    for (const s of opts.sampleColumns) {
        const g = opts.groupMapping?.[s] ?? infer(s);
        groups.push(g);
        infoLines.push(`${s}\t${g}`);
    }
    await writeFile(sampleInfoFile, infoLines.join('\n') + '\n', 'utf8');
    return {
        proteinFile,
        sampleInfoFile,
        keptRows: outRows.length,
        droppedRows,
        duplicateAccessions,
        groups: [...new Set(groups)],
    };
}
