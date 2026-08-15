# dsh-ezprot-plugin

[English](README.md) | [中文](docs/README.zh.md)

A plug-and-play **proteomics analysis plugin for DeepSeek Harness**. It wraps a full protein-expression analysis workflow — normalization → PCA → batch correction → differential analysis → GO/KEGG enrichment → GSEA — behind a conversation: give the agent your data file, answer a few questions (which columns are what, which groups to compare), and the plugin prepares everything automatically and walks through every step with visible summaries and figures, ending with an interpretation report.

No R, no Docker, no terminal knowledge required: the plugin detects or silently installs its own R 4.4.0 runtime and package library on first use (one-time, ~10–20 min).

## Install

Requires the [`dsh`](https://github.com/deepseek-ai/deepseek-harness) CLI (Windows / macOS / Linux), one command:

```bash
npx @deepseek-ai/dsh plugin --profile web add github:YukunR/dsh-ezprot-plugin
```

If `dsh` is already installed globally, drop the `npx @deepseek-ai/` prefix: 

```bash
dsh plugin --profile web add github:YukunR/dsh-ezprot-plugin
```

Then restart `dsh web`. Every session's agent gains the `proteomics_*` tools.

## Usage

Just talk to the agent. For example:

> My proteomics data is at `D:\my-experiment\origin_data.txt` with sample groups in `D:\my-experiment\sample_info.txt`, mouse samples. Compare HC and HD against NC.

The agent will inspect and QC your data, confirm the comparisons with you, run the analysis step by step, and write an interpretation report (top proteins, enriched pathways, candidate targets). Detailed instructions: [biologist's guide](docs/biologist-guide.md) ([中文](docs/biologist-guide.zh.md)).

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md).
