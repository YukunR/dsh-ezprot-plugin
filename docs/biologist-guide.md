# Proteomics Analysis Plugin · Guide for Biologists

[English](biologist-guide.md) | [中文](biologist-guide.zh.md)

> You don't need to install anything, learn R, or touch Docker.
> Everything runs inside DeepSeek Harness as a **conversation** — automatic and traceable, step by step.

## What you need

1. **A protein quantification result file** (tab-separated txt/tsv/csv, or **Excel**):
   - No need to tidy it yourself! Raw exports from MaxQuant / Proteome Discoverer etc. are fine (extra columns like molecular weight, coverage, PSM counts, even multi-sheet Excel files all work);
   - The plugin first reads the file, classifies the columns, and then **asks you a few questions**: which column is the protein ID, which is the gene name, which columns are samples, how samples are grouped, whether 0 means missing — just answer based on your data and it will tidy everything into the standard format;
   - If you already have a tidy table (first 3 columns: protein ID / gene name / description, one column per sample, `NaN` for missing values), just give it the path and skip this step.
2. Put the file in a folder on your computer (e.g. `D:\my-experiment\`) and tell the agent the path.
3. Be ready to answer two questions: **which groups to compare** (e.g. "HC vs NC, HD vs NC") and **whether your samples were prepared/run in batches** (if so, provide batch information for correction).

## How to use it

Just say, for example:

> My proteomics data is at `D:\my-experiment\origin_data.txt`, sample groups in `D:\my-experiment\sample_info.txt`, mouse samples. Compare HC and HD against NC.

Then it will:
1. **Check the environment automatically** (on first use it installs R and the required packages, ~10–20 min once; never again);
2. **QC your data automatically**, report the inferred groups and missingness, and **confirm the comparisons with you**;
3. Run each step — **normalization → PCA → (batch correction) → differential analysis → GO/KEGG enrichment → GSEA** — with a visible summary for every step in the conversation;
4. Finally give you an **interpretation report**: which proteins are up/down, which pathways are enriched, and which candidate targets deserve attention.

## Where the results are

Every step writes into the `res/` folder of your project directory:

```
res/norm_results/        normalization report, violin plots
res/pca_results/         PCA plots (sample clustering)
res/dea_results/<comparison>/   differential results CSV, volcano plots
                        ├─ enrichment_results/   GO/KEGG enrichment tables and figures
                        └─ gsea_results/         GSEA results
```

- **CSV** files open in Excel
- **PDF** figures can go straight into papers
- To redo a step: just say "redo the differential analysis with a stricter threshold (p<0.01)" — only the affected steps rerun

## FAQ

| Symptom | Meaning / what to do |
|---|---|
| "Installing packages for the first time, 10–20 min" | Normal — one-time only, fast afterwards |
| Warns about a missing Batch column | If samples were prepared in batches, add a `Batch` column to the sample table and rerun for more reliable results |
| A comparison has no significant proteins | The thresholds may be too strict — ask it to relax them or use automatic thresholds |
| Switching species (human/rat) | The first use of a species needs a one-time network build of its annotation background (cached afterwards) |
