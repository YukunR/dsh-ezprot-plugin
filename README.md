# dsh-ezprot-plugin

[English](README.md) | [中文](docs/README.zh.md)

A plug-and-play **proteomics analysis plugin for DeepSeek Harness**. It wraps a full protein-expression analysis workflow — normalization → PCA → batch correction → differential analysis → GO/KEGG enrichment → GSEA — behind a conversation: give the agent your data file, answer a few questions (which columns are what, which groups to compare), and the plugin prepares everything automatically and walks through every step with visible summaries and figures, ending with an interpretation report.

No R or terminal knowledge required: the plugin detects or silently installs its own R 4.4.0 runtime and package library on first use (one-time, ~10–20 min). Docker is optional: the plugin switches to a Docker backend automatically when a usable local R cannot be set up, and can run the one-time GO/KEGG background build inside the image on network-restricted machines.

## Install

### From the DSH Desktop plugin market

[DSH Desktop](https://github.com/anywhere-labs/deepseek-harness-desktop#dsh-desktop) ships an in-app plugin market. Add our catalog source once, then
install from the UI:

1. Settings → Plugins → Plugin market → Sources → **Add standard source**.
2. Enter `https://dsh-plugin.yukunr.top/catalog-source.json`.
3. Open **Discover**, search `ezprot`, and install `dsh-ezprot-plugin` from
   the card — Desktop re-verifies the exact version and the active profile
   before installing.
4. Restart Desktop and start a session: the `proteomics_*` tools are ready.

A step-by-step guide with screenshots: [安装指南 (中文)](docs/install.zh.md).

### From the command line

Prerequisites: Node.js (bundles `npx`) and pnpm — `npm install -g pnpm`.

Requires the [`dsh`](https://github.com/deepseek-ai/deepseek-harness) CLI (Windows / macOS / Linux), one command:

```bash
npx @deepseek-ai/dsh plugin --profile web add dsh-ezprot-plugin@0.1.1
```

If `dsh` is already installed globally, drop the `npx @deepseek-ai/` prefix: 

```bash
dsh plugin --profile web add dsh-ezprot-plugin@0.1.1
```

Then restart `dsh web`. Every session's agent gains the `proteomics_*` tools.

## Usage

Just talk to the agent. For example:

> My proteomics data is at `D:\my-experiment\origin_data.txt` with sample groups in `D:\my-experiment\sample_info.txt`, mouse samples. Compare HC and HD against NC.

The agent will inspect and QC your data, confirm the comparisons with you, run the analysis step by step, and write an interpretation report (top proteins, enriched pathways, candidate targets). Detailed instructions: [biologist's guide](docs/biologist-guide.md) ([中文](docs/biologist-guide.zh.md)).

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md).
