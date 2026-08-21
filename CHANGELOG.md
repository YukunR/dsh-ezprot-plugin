# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- Install command in `README.md` / `docs/README.zh.md` now pins the version (`add dsh-ezprot-plugin@0.1.1`): pnpm 11's supply-chain default `minimumReleaseAge` (24h) makes bare `add` and `@latest` resolve to the previous release during the first day after a publish, so the docs pin the version and the release checklist keeps them in sync.
- DSH Desktop market availability: an official catalog source (`https://dsh-plugin.yukunr.top/catalog-source.json`) lets Desktop users discover and install the plugin from the in-app plugin market; added a Chinese installation guide with screenshots (`docs/install.zh.md`) and documented the optional Docker backend in both READMEs.

## [0.1.1] - 2026-08-16

### Changed
- Install path moved to the npm registry (`dsh plugin add dsh-ezprot-plugin`): end users need only Node.js and pnpm — no git, no build on install (the `prepare` script is gone; the committed `lib/` is used as-is).
- Package installer hardened against mirror rate-limits and missing Rtools: install retries verify the package really appears in the library (HTTP 429 warnings can no longer masquerade as success); annotation data packages (GO.db, GenomeInfoDbData, ...) install from single source tarballs instead of the parallel-make path; a dependency-closure pass plus a multi-round whole-manifest audit installs missing Imports/Depends/LinkingTo until the closure is complete; png gets multi-mirror binary retries (Westlake-first, TUNA-free) with a bounded source fallback on Windows.
- Manifest now lists `png`, `ape`, and `UCSC.utils` explicitly so the verified retries cover them from the first pass.

### Fixed
- False "interrupted step" warning on every step run: the success-path checkpoint reload no longer treats the in-flight step as a stale interruption.
- Enrichment and GSEA now run through the checkpoint framework (completion markers, output hashes, comparison-config tracking, dependency validation, `--rerun` support) instead of bypassing it.

## [0.1.0] - 2026-08-15

### Added
- Bundle-format plugin (`dsh.bundle`) installed with one `dsh plugin add` command.
- Eight agent tools: `proteomics_environment`, `proteomics_background`, `proteomics_import`, `proteomics_preflight`, `proteomics_compare`, `proteomics_batch`, `proteomics_step`, `proteomics_report`.
- Step-wise traceable pipeline — normalization → PCA → (batch removal) → DEA → enrichment → GSEA, one tool call per stage with structured CSV-derived summaries; comparisons are confirmed by the user and a PCA review gate pauses before DEA (human-in-the-loop decision points).
- Auto-managed R runtime: R 4.4.0 discovery/silent install (no admin rights), persistent package library (install-missing-only, Bioc 3.20 pinned), Westlake University mirrors with retries and fallbacks, offline snapshot restore, and an optional Docker backend (pull + in-container verification, persisted backend choice, `--mount`-based bind mounts for Windows hosts).
- Raw data import (`proteomics_import`): TSV/CSV/Excel with column classification heuristics, interactive confirmation, and tidying into the canonical matrix.
- Per-organism GO/KEGG annotation backgrounds built once on demand from KEGG REST + UniProt and cached permanently; builds can run inside the Docker image so network-restricted host sandboxes still work.
- Deep runtime probe (`action=verify`): loads every manifest package and exercises PCAtools encircle/ggalt, ComBat, and enricher smoke paths.
- Streaming, cancellable background setup jobs with pollable progress.
- TypeScript sources (`src/`) built to `lib/` (+ `.d.ts`), vitest unit tests, GitHub Actions CI, and `link:`-protocol development install.
- English/Chinese bilingual docs with language switchers (README, biologist's guide, CONTRIBUTING).

### Changed
- Senior-review hardening pass (P1/P2/P3): per-attempt download timeouts and a 30-minute R installer bound; docker-backed steps verify the image is pulled before running; preflight flags non-numeric annotation columns (MaxQuant "Reverse"/"Potential contaminant") instead of treating them as samples; project input copies skip self-copies; cross-platform local R detection (`which`/`where`, POSIX roots); snapshot paths travel via environment variables (`-LiteralPath`); runtime state writes are atomic and serialized; tool `execute` signatures use framework-inferred types; workflow rules live only in the system-prompt section; the fallback docker image name is one constant.
- Project layout: setup R scripts moved to `r/setup/`, the linux diagnostic probe moved to `scripts/`, and the monolithic `runtime.ts` split by responsibility into `src/runtime/` behind an unchanged public facade.
- No annotation backgrounds ship with the plugin: every organism (human/mouse/rat) builds them once on first use and caches them permanently (`data/` is gitignored).
- Linux package installs in `install_packages.R` are platform-aware: CRAN packages come from a date-pinned Posit PPM binary snapshot (2024-11-15, the Bioc 3.20 era — PPM "latest" now targets R ≥ 4.5 and breaks Bioc 3.20 packages like ggtree; codename auto-detected; Westlake mirrors carry no Linux binaries), Bioc 3.20 packages build from source against the Westlake Bioc mirror, and archived gghalves/ggalt come from the Westlake CRAN archive (with a header-only BH refresh from the source mirror because Bioc 3.20 patch releases need BH ≥ 1.87.0). BiocManager bootstrap gained retries plus a source-mirror fallback for flaky blob-host DNS. The Docker image installs required system libraries via apt (`APT_MIRROR`/`APT_MIRROR_BACKUP` build args with retries).
- Figure viewing is model-capability-dependent: `read_image` on the PCA PNGs when the model supports image input, numeric-summary narration otherwise (figures never embedded in tool cards).
- Background-build R scripts hardened for the clean image environment: explicit `dplyr::` prefixes (plyr shadowing) and dependency-free statistics; docker backend uses container script paths.
- Fresh-machine package installation hardened (ggalt added to the manifest, probe false-positive fix, pristine-R end-to-end test).
- Renamed to `dsh-ezprot-plugin` (matching the repository name).
