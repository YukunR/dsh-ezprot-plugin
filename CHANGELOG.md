# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- TypeScript sources (`src/`) with `tsc` build to `lib/` (+ `.d.ts`), aligned with official DSH plugin conventions.
- Vitest unit tests (`tests/unit/`) and GitHub Actions CI (`pnpm install → tsc → vitest`).
- `link:`-protocol development install documented in README (live source reload after `pnpm build`).
- Docker installation backend: `docker/Dockerfile` builds R 4.4.0 + the exact package manifest and FAILS the build unless the in-image runtime probe passes; published images are pulled as-is so end users never depend on mirror quality. The plugin runs `docker pull` + in-container verification, persists the backend choice, and the agent asks the user to choose Docker vs local R.
- Streaming setup progress for `proteomics_environment action=setup` (background job + pollable logs).
- Deep runtime probe (`proteomics_environment action=verify`): loads every manifest package and exercises PCAtools encircle/ggalt, ComBat, and enricher smoke paths to catch Suggests-only gaps.

### Changed
- Linux package installs in `install_packages.R` are now platform-aware: CRAN packages come from a date-pinned Posit PPM binary snapshot (2024-11-15, the Bioc 3.20 era — PPM "latest" now targets R ≥ 4.5 and breaks Bioc 3.20 packages like ggtree; codename auto-detected; Westlake mirrors carry no Linux binaries), Bioc 3.20 packages build from source against the Westlake Bioc mirror, and archived gghalves/ggalt come from the Westlake CRAN archive (with a header-only BH refresh from the source mirror because Bioc 3.20 patch releases need BH ≥ 1.87.0). BiocManager bootstrap gained retries plus a source-mirror fallback for flaky blob-host DNS. The Docker image now installs required system libraries via apt (libuv1/zlib1g-dev/libxml2-dev/libglpk40/libcairo2/...; `APT_MIRROR`/`APT_MIRROR_BACKUP` build args with retries for networks without archive.ubuntu.com or with rate-limited mirrors).
- Figure viewing is model-capability-dependent: `read_image` on the PCA PNGs when the model supports image input, numeric-summary narration otherwise (figures never embedded in tool cards).
- Fresh-machine package installation hardened (ggalt added to the manifest, probe false-positive fix, pristine-R end-to-end test).

## [0.1.0] - 2026-08-14

### Added
- Bundle-format plugin (`dsh.bundle`) for one-command install via `dsh plugin add`.
- Five agent tools: `proteomics_environment`, `proteomics_background`, `proteomics_preflight`, `proteomics_step`, `proteomics_report`.
- Step-wise traceable pipeline: normalization → PCA → (batch removal) → DEA → enrichment → GSEA, each step as one tool call with structured CSV-derived summaries.
- Auto-managed R runtime: R 4.4.0 discovery/silent install (no admin), persistent package library (install-missing-only, Bioc 3.20 pinned), Westlake University mirrors with fallbacks and retries, offline snapshot restore, optional Docker backend.
- Non-interactive R pipeline port (batch removal driven by the `Batch` column; `dea`/`enrich`/`gsea` split into separate steps; GSEA pathway plot cap at 30).
- Shipped mouse GO/KEGG backgrounds; human/rat built once on demand and cached.
- End-to-end validated on a real mouse dataset (8,757 proteins × 15 samples).
