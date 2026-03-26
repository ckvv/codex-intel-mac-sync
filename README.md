# codex-intel-mac

Single-script workflow to rebuild Codex Desktop for Intel macOS from a source `Codex.dmg` or `Codex.app`.

## Automation

- Scheduled GitHub Action: [`.github/workflows/rebuild-intel-codex.yml`](.github/workflows/rebuild-intel-codex.yml)
- Workflow notes: [`docs/auto-release.md`](docs/auto-release.md)

## Script

- `./codex-intel.sh`

## Behavior

- Running with no arguments prints usage + quick start instructions.
- If Xcode Command Line Tools are missing, the script asks to install them and triggers `xcode-select --install`.
- If no source app is found, the script tells you to provide `Codex.dmg`/`Codex.app` and shows a download page.

## Download Codex.dmg

- https://openai.com/codex/get-started/

## Quick Start

1. Put `Codex.dmg` in this folder (`./Codex.dmg`), or pass `--source-dmg`.
2. Run:

```bash
./codex-intel.sh --dmg
```

Outputs:

- `./dist/Codex-Intel.dmg`

Output selection:

- `--dmg`: output DMG
- `--app`: output rebuilt app
- `--app --dmg`: output both
- If neither is provided, default is `--dmg` only.

## Common Commands

Full flow (build + repackage + dmg):

```bash
./codex-intel.sh --source-dmg ./Codex.dmg --dmg
```

Output app only:

```bash
./codex-intel.sh --source-dmg ./Codex.dmg --app
```

Output both app + dmg:

```bash
./codex-intel.sh --source-dmg ./Codex.dmg --app --dmg
```

Use an installed app instead of dmg:

```bash
./codex-intel.sh --source-app /Applications/Codex.app --dmg
```

Build artifacts only:

```bash
./codex-intel.sh --build-only
```

Repackage only (reuse existing `.build`):

```bash
./codex-intel.sh --repackage-only --source-dmg ./Codex.dmg
```

DMG only:

```bash
./codex-intel.sh --dmg-only --dmg-source-app ./dist/Codex-Intel.app
```

## DMG Window/Layout Options

Defaults:

- `--window-width 840`
- `--window-height 520`
- `--app-icon-x 240 --app-icon-y 260`
- `--apps-icon-x 650 --apps-icon-y 260`

Example:

```bash
./codex-intel.sh --dmg-only \
  --dmg-source-app ./dist/Codex-Intel.app \
  --output-dmg ./dist/Codex-Intel.dmg \
  --window-width 820 \
  --window-height 500
```

## Help

```bash
./codex-intel.sh --help
```
