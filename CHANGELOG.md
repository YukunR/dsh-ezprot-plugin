# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- TypeScript sources (`src/`) with `tsc` build to `lib/` (+ `.d.ts`), aligned with official DSH plugin conventions.
- Vitest unit tests (`tests/unit/`) and GitHub Actions CI (`pnpm install → tsc → vitest`).
- `link:`-protocol development install documented in README (live source reload after `pnpm build`).

## [0.1.0] - 2026-08-14

### Added
- Bundle-format plugin (`dsh.bundle`) for one-command install via `dsh plugin add`.
- Five agent tools: `proteomics_environment`, `proteomics_background`, `proteomics_preflight`, `proteomics_step`, `proteomics_report`.
- Step-wise traceable pipeline: normalization → PCA → (batch removal) → DEA → enrichment → GSEA, each step as one tool call with structured CSV-derived summaries.
- Auto-managed R runtime: R 4.4.0 discovery/silent install (no admin), persistent package library (install-missing-only, Bioc 3.20 pinned), Westlake University mirrors with fallbacks and retries, offline snapshot restore, optional Docker backend.
- Non-interactive R pipeline port (batch removal driven by the `Batch` column; `dea`/`enrich`/`gsea` split into separate steps; GSEA pathway plot cap at 30).
- Shipped mouse GO/KEGG backgrounds; human/rat built once on demand and cached.
- End-to-end validated on a real mouse dataset (8,757 proteins × 15 samples).
