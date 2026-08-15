# Contributing

Thanks for your interest in contributing! This project follows the official
DeepSeek Harness plugin conventions ([plugin development docs](https://deepseek-harness.github.io/deepseek-harness/develop/basic/)).

## Getting started

```powershell
pnpm install   # devDeps: typescript + @deepseek-ai/* pinned to the deployment versions
pnpm build     # tsc: src/*.ts -> lib/*.js (+ .d.ts)
pnpm test      # vitest unit tests (no R required)
```

Development install (live link into a profile):

```powershell
dsh plugin --profile web add "link:D:/ResearchProject/ezprot-dsh-plugin"
```

`src/*.ts` changes need `pnpm build`; `r/` script changes apply to newly
preflighted projects immediately.

## Layout

| Path | Purpose |
|---|---|
| `src/` | TypeScript plugin sources (built to `lib/`) |
| `lib/` | Build artifacts (committed; git installs need no build step) |
| `r/` | R compute engine (vendored pipeline + `run.R` step driver) |
| `manifest/packages.json` | Required R package manifest (R 4.4.0 / Bioc 3.20) |
| `cordis.patch.yml` | Bundle configuration layer (defaults only) |
| `tests/unit/` | Vitest unit tests |
| `tests/e2e/` | End-to-end drivers (need local R 4.4 + a complete R library) |
| `tests/fixtures/` | Sample mouse dataset used by the e2e drivers |
| `docker/` | Optional Docker backend image |
| `scripts/` | Deployment tooling (installer, offline snapshot builder, linux diag probe) |

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
3. For new organisms or parameters, update `README.md` and
   `docs/biologist-guide.zh.md`.
