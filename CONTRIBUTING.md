# Contributing

[English](CONTRIBUTING.md) | [中文](docs/CONTRIBUTING.zh.md)

Thanks for your interest in contributing! This project follows the official
DeepSeek Harness plugin conventions ([plugin development docs](https://deepseek-harness.github.io/deepseek-harness/develop/basic/)).

## Development setup

```powershell
pnpm install   # devDeps: typescript + @deepseek-ai/* pinned to the deployment versions
pnpm build     # tsc: src/*.ts -> lib/*.js (+ .d.ts)
pnpm test      # vitest unit tests (no R required)
```

Development install (live link into a profile):

```powershell
dsh plugin --profile web add "link:<absolute-path-to-this-repo>"
```

- The `link:` protocol is a symlink: `src/*.ts` changes only need `pnpm build`
  (no reinstall); `r/` script or `cordis.patch.yml` changes apply directly.
- End users are unaffected: npm/github/tarball installs are static snapshots
  (`lib/` is committed, so git installs need no build step).
- CI: `.github/workflows/ci.yml` (`pnpm install → tsc → vitest`).
- Machines without pnpm: `scripts/install.ps1` (tries `dsh plugin add` first,
  falls back to copying the real path).

## Development verification

```powershell
node --check lib\*.js        # syntax check
node tests\e2e\mount-smoke.mjs   # bundle resolution + apply() + 8-tool registration (no R)
node tests\e2e\drive.mjs         # full pipeline over the fixtures mouse dataset (needs local R 4.4.0 + complete library)
node tests\e2e\summary-check.mjs # step-summary checks against a finished project
node tests\e2e\env-fresh.mjs     # pristine-machine install simulation (fresh R + empty library)
```

## Layout

| Path | Purpose |
|---|---|
| `src/` | TypeScript plugin sources (built to `lib/`) |
| `lib/` | Build artifacts (committed; git installs need no build step) |
| `r/` | R compute engine (`setup/` env scripts, `run.R` step driver, `core/`, `utils/`, `background/`, `import/`) |
| `manifest/packages.json` | Required R package manifest (R 4.4.0 / Bioc 3.20) |
| `cordis.patch.yml` | Bundle configuration layer (defaults only) |
| `tests/unit/` | Vitest unit tests |
| `tests/e2e/` | End-to-end drivers (need local R 4.4 + a complete R library) |
| `tests/fixtures/` | Sample mouse dataset used by the e2e drivers |
| `docker/` | Optional Docker backend image (build & publish guide: `docker/README.md`) |
| `scripts/` | Deployment tooling (installer, offline snapshot builder, linux diag probe) |

## Configuration

The plugin ships defaults in `cordis.patch.yml`; machine-specific overrides
belong in the profile's own `cordis.patch.yml` (id-targeted) or
`$DSH_HOME/cordis.patch.yml`:

| Field | Default | Meaning |
|---|---|---|
| `dataDir` | `$DSH_HOME/proteomics` | Runtime cache (R install, package library, backgrounds, downloads) |
| `libraryDir` | `dataDir/runtime/library` | R package library; point at an existing complete library (e.g. a renv library) to skip installation |
| `rscript` | auto-detected | Pin a Rscript path |
| `cranRepo` | Westlake CRAN | CRAN mirror |
| `biocRepo` | Westlake Bioconductor | Bioconductor mirror |
| `enableInstall` | `true` | Allow automatic R/package installation |
| `defaultTimeoutMs` | `1800000` | Per-step timeout |
| `backend` | `auto` | `auto` (local R preferred; docker when no local R but Docker exists) / `local` / `docker` |
| `dockerImage` | `yukunru/ezprot:latest` | Image used by the docker backend |

## Conventions

- Keep the bundle patch (`cordis.patch.yml`) to defaults most users keep;
  machine-specific values belong in the profile's own `cordis.patch.yml`.
- Everything tunable must be a `Config` field with a schema default — never
  hardcode values two deployments may want to differ.
- All registrations happen inside `apply()` so HMR/unload cleans them up.
- Prefer structured summaries (CSV-derived) over parsing R log text.
- Bump `CHANGELOG.md` with every user-visible change.

## Pull requests

1. `pnpm build && pnpm test` must pass.
2. Keep the R pipeline changes minimal and non-interactive (no `readline()`).
3. For new organisms or parameters, update `README.md` and the biologist
   guides (`docs/biologist-guide.md` / `docs/biologist-guide.zh.md`).
