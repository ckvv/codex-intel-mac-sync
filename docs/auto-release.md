# Auto Release Workflow

This repository includes a scheduled GitHub Actions workflow at `.github/workflows/rebuild-intel-codex.yml`.

## What It Does

On every scheduled run, the workflow:

1. Downloads the upstream `Codex.dmg` from `https://persistent.oaistatic.com/codex-app-prod/Codex.dmg`.
2. Mounts the DMG and reads `CFBundleShortVersionString` and `CFBundleVersion` from the bundled app.
3. Computes the upstream DMG SHA256.
4. Uses `version + build + sha12` to derive a release tag.
5. Skips the build if that exact upstream DMG was already published as a GitHub release.
6. Otherwise installs the official `@openai/codex` CLI on the Intel runner and calls `./codex-intel.sh` to rebuild an Intel-compatible DMG.
7. Uploads the generated DMG as both a workflow artifact and a GitHub release asset.

## Trigger Modes

- Scheduled: every 6 hours
- Manual: `workflow_dispatch`

## Why The Release Tag Includes SHA

The workflow does not rely on version number alone. If the upstream `Codex.dmg` is silently replaced without a version bump, a new SHA256 will still produce a new release tag, so the repack step runs again.

## Output Naming

Generated assets use this pattern:

- `Codex-Intel-<version>-<build>-<sha12>.dmg`

## Runner Choice

The workflow uses the `macos-15-intel` GitHub-hosted runner so the temporary global `@openai/codex` install includes an Intel vendor binary that can be bundled into the repackaged app.

Recent `@openai/codex` installs expose `codex` as a Node launcher script in `$PATH`, not as the Mach-O binary itself. `./codex-intel.sh` now resolves that launcher back to the packaged `@openai/codex-darwin-x64` binary automatically during repackaging, so the workflow does not need to pass `command -v codex` explicitly.
