# Repository Guidelines

## Project Structure & Module Organization
`codex-intel.sh` is the main entrypoint and owns the local rebuild/repackage flow for Intel macOS. Keep supporting automation under [`.github/`](./.github), especially [`.github/workflows/rebuild-intel-codex.yml`](./.github/workflows/rebuild-intel-codex.yml) and [`.github/scripts/inspect-upstream-codex.sh`](./.github/scripts/inspect-upstream-codex.sh). Write user-facing behavior notes in [`docs/`](./docs); update docs whenever a public utility or workflow behavior changes. Treat [`dist/`](./dist) and [`.build/`](./.build) as generated output, not hand-edited source.

## Build, Test, and Development Commands
Run the script from the repo root:

- `./codex-intel.sh --help` shows supported modes and flags.
- `./codex-intel.sh --source-dmg ./Codex.dmg --dmg` performs the standard rebuild and emits `dist/Codex-Intel.dmg`.
- `./codex-intel.sh --build-only` rebuilds Electron/native artifacts without repackaging.
- `./codex-intel.sh --repackage-only --source-dmg ./Codex.dmg` reuses an existing `.build/` workspace.
- `bash -n codex-intel.sh` and `bash -n .github/scripts/inspect-upstream-codex.sh` catch shell syntax errors before committing.

## Coding Style & Naming Conventions
Use Bash with `set -euo pipefail`, short helper functions, and clear guard clauses. Match the existing style: uppercase names for exported/config variables (`REPO_ROOT`), lowercase for locals (`mount_point`), and dash-style long CLI flags such as `--source-dmg`. Indent shell blocks with two spaces only when wrapping heredocs or lists requires it; otherwise follow the current script’s minimal indentation style. Prefer portable POSIX-friendly utilities unless the script already depends on macOS tooling like `hdiutil` or `defaults`.

## Testing Guidelines
There is no formal test suite yet. Validate changes by running the relevant script mode, plus syntax checks with `bash -n`. If you change release automation, review [`docs/auto-release.md`](./docs/auto-release.md) and, when possible, verify the workflow logic against a manual dry run.

## Commit & Pull Request Guidelines
The current history uses short, imperative commit subjects (`Initial commit: codex-intel-mac`). Continue with concise summaries focused on one change. PRs should include the user-visible effect, commands run for validation, linked issues when applicable, and screenshots only when DMG layout or release UI output changed.

## Contributor Notes
Ask for confirmation before adding new production dependencies. Do not commit generated artifacts from `.build/` unless the change explicitly requires refreshed build metadata.
