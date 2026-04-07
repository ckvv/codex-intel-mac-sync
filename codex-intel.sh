#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  codex-intel.sh [options]

Main flow (default):
  1) Build Intel artifacts
  2) Repackage Codex.app to Intel
  3) Optional DMG creation with --dmg

Mode options:
  --build-only                 Build artifacts only
  --repackage-only             Repackage only (no artifact build)
  --dmg-only                   Create DMG only

Input options:
  --source-app <path>          Source Codex.app path
  --source-dmg <path>          Source Codex.dmg path (default: <repo>/Codex.dmg when present)
  --dmg-source-app <path>      App path to package into dmg (default: --output-app)

Output options:
  --app                        Keep/output rebuilt app
  --dmg                        Create/output dmg
  --output-app <path>          Output app (default: <repo>/dist/Codex-Intel.app)
  --output-dmg <path>          Output dmg (default: <repo>/dist/Codex-Intel.dmg)
  --workdir <path>             Build workdir (default: <repo>/.build/codex-intel-build)
  (If neither --app nor --dmg is provided, default output is --dmg only.)

Build options:
  --skip-build                 Skip artifact build
  --force-clean                Remove workdir before build
  --electron-version <ver>     Electron version (default: 40.0.0)
  --better-sqlite3-version <v> better-sqlite3 version (default: 12.5.0)
  --node-pty-version <ver>     node-pty version (default: 1.1.0)

Repackage options:
  --cli-bin <path>             Force Intel codex CLI path (binary or npm launcher)
  --skip-cli-bundle            Do not bundle codex CLI
  --sparkle-node <path>        Optional Intel sparkle.node

DMG layout options:
  --volname <name>             DMG volume name (default: Codex Intel)
  --window-width <px>          Finder window width (default: 840)
  --window-height <px>         Finder window height (default: 520)
  --window-left <px>           Finder window left (default: 100)
  --window-top <px>            Finder window top (default: 100)
  --app-icon-x <px>            App icon X position (default: 240)
  --app-icon-y <px>            App icon Y position (default: 260)
  --apps-icon-x <px>           Applications icon X position (default: 650)
  --apps-icon-y <px>           Applications icon Y position (default: 260)

Misc:
  -h, --help                   Show help
EOF
}

print_quick_help() {
  cat <<'EOF'

Quick Start:
  ./codex-intel.sh --dmg

If you don't have Codex.dmg yet:
  1) Download from: https://openai.com/codex/get-started/
  2) Place it at:   ./Codex.dmg
  3) Re-run:        ./codex-intel.sh --dmg
EOF
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "Missing file: $path"
}

require_dir() {
  local path="$1"
  [[ -d "$path" ]] || die "Missing directory: $path"
}

first_existing() {
  local candidate
  for candidate in "$@"; do
    if [[ -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

is_x86_64_binary() {
  local path="$1"
  local info
  info="$(file -b "$path" 2>/dev/null || true)"
  [[ "$info" == *"x86_64"* ]]
}

require_x86_64_binary() {
  local path="$1"
  require_file "$path"
  is_x86_64_binary "$path" || die "Expected x86_64 binary, but got: $path ($(file -b "$path"))"
}

copy_file() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
}

copy_dir() {
  local src="$1"
  local dst="$2"
  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  ditto "$src" "$dst"
}

find_app_in_dir() {
  local dir="$1"
  local app_path=""

  if [[ -d "${dir}/Codex.app" ]]; then
    printf '%s\n' "${dir}/Codex.app"
    return 0
  fi

  app_path="$(find "$dir" -maxdepth 1 -type d -name '*.app' | head -n 1 || true)"
  [[ -n "$app_path" ]] || return 1
  printf '%s\n' "$app_path"
}

extract_app_from_dmg() {
  local dmg_path="$1"
  local out_app="$2"
  local attach_output mount_point app_in_dmg

  require_file "$dmg_path"

  attach_output="$(hdiutil attach "$dmg_path" -readonly -nobrowse 2>/dev/null || true)"
  mount_point="$(printf '%s\n' "$attach_output" | awk 'match($0,/\/Volumes\/.*/){print substr($0, RSTART, RLENGTH); exit}')"
  [[ -n "$mount_point" ]] || die "Failed to mount dmg: $dmg_path"

  app_in_dmg="$(find_app_in_dir "$mount_point" || true)"
  if [[ -z "$app_in_dmg" ]]; then
    hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    die "No .app bundle found inside: $dmg_path"
  fi

  rm -rf "$out_app"
  mkdir -p "$(dirname "$out_app")"
  ditto "$app_in_dmg" "$out_app"
  hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
}

resolve_symlink_path() {
  local path="$1"
  local target=""
  local path_dir=""

  while [[ -L "$path" ]]; do
    target="$(readlink "$path")"
    if [[ "$target" == /* ]]; then
      path="$target"
    else
      path_dir="$(cd "$(dirname "$path")" && pwd -P)"
      path="${path_dir}/${target}"
    fi
  done

  printf '%s\n' "$path"
}

print_cli_bin_candidates_from_hint() {
  local hint="$1"
  local resolved_hint=""
  local hint_dir=""
  local hint_prefix=""
  local package_root=""

  [[ -n "$hint" ]] || return 0

  printf '%s\n' "$hint"

  if [[ -e "$hint" || -L "$hint" ]]; then
    resolved_hint="$(resolve_symlink_path "$hint")"
    [[ "$resolved_hint" != "$hint" ]] && printf '%s\n' "$resolved_hint"

    if [[ "$resolved_hint" == *"/node_modules/@openai/codex/"* ]]; then
      package_root="${resolved_hint%%/node_modules/@openai/codex/*}/node_modules/@openai/codex"
      printf '%s\n' "${package_root}/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex"
    fi
  fi

  hint_dir="$(dirname "$hint")"
  if [[ "$(basename "$hint_dir")" == "bin" ]]; then
    hint_prefix="$(cd "${hint_dir}/.." && pwd -P 2>/dev/null || true)"
    if [[ -n "$hint_prefix" ]]; then
      printf '%s\n' "${hint_prefix}/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex"
      printf '%s\n' "${hint_prefix}/lib/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex"
    fi
  fi
}

resolve_cli_bin_hint() {
  local hint="$1"
  local candidate=""

  while IFS= read -r candidate; do
    if [[ -x "$candidate" ]] && is_x86_64_binary "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(print_cli_bin_candidates_from_hint "$hint")

  return 1
}

detect_cli_bin() {
  local npm_root=""
  local codex_path=""
  local candidate

  if command -v codex >/dev/null 2>&1; then
    codex_path="$(command -v codex || true)"
    candidate="$(resolve_cli_bin_hint "$codex_path" || true)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if command -v npm >/dev/null 2>&1; then
    npm_root="$(npm root -g 2>/dev/null || true)"
  fi

  if [[ -n "$npm_root" ]]; then
    for candidate in \
      "${npm_root}/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex" \
      "${npm_root}/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex"
    do
      if [[ -x "$candidate" ]] && is_x86_64_binary "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  for candidate in \
    "/usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex" \
    "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex" \
    "/usr/local/bin/codex" \
    "/opt/homebrew/bin/codex"
  do
    if [[ -x "$candidate" ]] && is_x86_64_binary "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_global_codex_cli() {
  if command -v codex >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    return 1
  fi

  log "Intel Codex CLI not found; installing globally via npm"
  npm install -g @openai/codex --registry https://registry.npmmirror.com/ --no-audit
}

prepare_artifacts() {
  require_command npm
  require_command npx
  require_command xcode-select

  if [[ "$SKIP_CLI_BUNDLE" -eq 0 ]]; then
    ensure_global_codex_cli || true
  fi

  if ! xcode-select -p >/dev/null 2>&1; then
    log "Xcode Command Line Tools are required."
    log "Attempting to launch installer: xcode-select --install"
    xcode-select --install >/dev/null 2>&1 || true
    die "Install Xcode Command Line Tools, then run again."
  fi

  if [[ "$FORCE_CLEAN" -eq 1 ]]; then
    log "Removing existing workdir: $WORKDIR"
    rm -rf "$WORKDIR"
  fi

  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  if [[ ! -f package.json ]]; then
    log "Initializing npm project in $WORKDIR"
    npm init -y >/dev/null
  fi

  log "npm registry: $(npm config get registry 2>/dev/null || true)"
  log "Installing build dependencies"
  npm install --loglevel verbose \
    "electron@${ELECTRON_VERSION}" \
    "better-sqlite3@${BETTER_SQLITE3_VERSION}" \
    "node-pty@${NODE_PTY_VERSION}" \
    "@electron/rebuild"

  if [[ ! -d node_modules/electron/dist/Electron.app ]]; then
    log "Downloading Electron runtime payload"
    (cd node_modules/electron && node install.js)
  fi

  log "Rebuilding native modules for Electron x64"
  npx electron-rebuild \
    -f \
    -w better-sqlite3,node-pty \
    --arch x64 \
    --version "$ELECTRON_VERSION" \
    --module-dir .

  ELECTRON_APP="${WORKDIR}/node_modules/electron/dist/Electron.app"
  BETTER_SQLITE3_NODE="${WORKDIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  PTY_NODE="$(first_existing \
    "${WORKDIR}/node_modules/node-pty/build/Release/pty.node" \
    "${WORKDIR}/node_modules/node-pty/prebuilds/darwin-x64/pty.node")"
  SPAWN_HELPER="$(first_existing \
    "${WORKDIR}/node_modules/node-pty/build/Release/spawn-helper" \
    "${WORKDIR}/node_modules/node-pty/prebuilds/darwin-x64/spawn-helper")"

  require_dir "$ELECTRON_APP"
  require_file "$BETTER_SQLITE3_NODE"
  require_file "$PTY_NODE"
  require_file "$SPAWN_HELPER"

  cat > "${WORKDIR}/artifact-paths.env" <<EOF
ELECTRON_APP=${ELECTRON_APP}
BETTER_SQLITE3_NODE=${BETTER_SQLITE3_NODE}
PTY_NODE=${PTY_NODE}
SPAWN_HELPER=${SPAWN_HELPER}
EOF
}

resolve_source_app() {
  if [[ -n "$SOURCE_APP" ]]; then
    require_dir "$SOURCE_APP"
    return 0
  fi

  if [[ -n "$SOURCE_DMG" ]]; then
    if [[ ! -f "$SOURCE_DMG" ]]; then
      cat >&2 <<EOF
Missing source dmg: $SOURCE_DMG
Download Codex.dmg from:
  https://openai.com/codex/get-started/
Then place it at ./Codex.dmg or pass --source-dmg <path>.
EOF
      exit 1
    fi
    SOURCE_APP="${REPO_ROOT}/.build/source/Codex.app"
    log "Extracting source app from dmg"
    extract_app_from_dmg "$SOURCE_DMG" "$SOURCE_APP"
    return 0
  fi

  if [[ -d "/Applications/Codex.app" ]]; then
    SOURCE_APP="/Applications/Codex.app"
    return 0
  fi

  cat >&2 <<'EOF'
No source app found.
Provide one of:
  --source-app /path/to/Codex.app
  --source-dmg /path/to/Codex.dmg

Download Codex.dmg:
  https://openai.com/codex/get-started/
EOF
  exit 1
}

ensure_source_app() {
  if [[ "$SOURCE_RESOLVED" -eq 0 ]]; then
    resolve_source_app
    SOURCE_RESOLVED=1
  fi
}

resolve_artifacts_from_workdir() {
  require_dir "$WORKDIR"

  ELECTRON_APP="${WORKDIR}/node_modules/electron/dist/Electron.app"
  BETTER_SQLITE3_NODE="${WORKDIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  PTY_NODE="$(first_existing \
    "${WORKDIR}/node_modules/node-pty/build/Release/pty.node" \
    "${WORKDIR}/node_modules/node-pty/prebuilds/darwin-x64/pty.node")"
  SPAWN_HELPER="$(first_existing \
    "${WORKDIR}/node_modules/node-pty/build/Release/spawn-helper" \
    "${WORKDIR}/node_modules/node-pty/prebuilds/darwin-x64/spawn-helper")"
}

repackage_app() {
  local output_frameworks_dir output_resources_dir output_unpacked_dir
  local framework helper
  local resolved_cli_bin=""

  resolve_artifacts_from_workdir

  [[ -n "$CLI_BIN" ]] || CLI_BIN="$(first_existing \
    "${WORKDIR}/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex" \
    "${WORKDIR}/node_modules/@openai/codex/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/codex/codex" \
    "${WORKDIR}/codex" || true)"

  if [[ -n "$CLI_BIN" && "$SKIP_CLI_BUNDLE" -eq 0 ]]; then
    resolved_cli_bin="$(resolve_cli_bin_hint "$CLI_BIN" || true)"
    if [[ -n "$resolved_cli_bin" && "$resolved_cli_bin" != "$CLI_BIN" ]]; then
      log "Resolved Intel codex CLI from launcher path: $resolved_cli_bin"
      CLI_BIN="$resolved_cli_bin"
    fi
  fi

  if [[ -z "$CLI_BIN" && "$SKIP_CLI_BUNDLE" -eq 0 ]]; then
    CLI_BIN="$(detect_cli_bin || true)"
    if [[ -n "$CLI_BIN" ]]; then
      log "Auto-detected Intel codex CLI: $CLI_BIN"
    else
      log "Intel codex CLI not found; proceeding without bundling CLI"
      SKIP_CLI_BUNDLE=1
    fi
  fi

  require_dir "$SOURCE_APP"
  require_dir "$ELECTRON_APP"
  require_file "$BETTER_SQLITE3_NODE"
  require_file "$PTY_NODE"
  require_file "$SPAWN_HELPER"
  if [[ "$SKIP_CLI_BUNDLE" -eq 0 ]]; then
    require_x86_64_binary "$CLI_BIN"
  fi
  if [[ -n "$SPARKLE_NODE" ]]; then
    require_file "$SPARKLE_NODE"
  fi

  local electron_main="${ELECTRON_APP}/Contents/MacOS/Electron"
  local electron_frameworks_dir="${ELECTRON_APP}/Contents/Frameworks"
  require_file "$electron_main"
  require_dir "$electron_frameworks_dir"

  for framework in \
    "Electron Framework.framework" \
    "Mantle.framework" \
    "ReactiveObjC.framework" \
    "Squirrel.framework"
  do
    require_dir "${electron_frameworks_dir}/${framework}"
  done

  for helper in \
    "Electron Helper.app/Contents/MacOS/Electron Helper" \
    "Electron Helper (GPU).app/Contents/MacOS/Electron Helper (GPU)" \
    "Electron Helper (Plugin).app/Contents/MacOS/Electron Helper (Plugin)" \
    "Electron Helper (Renderer).app/Contents/MacOS/Electron Helper (Renderer)"
  do
    require_file "${electron_frameworks_dir}/${helper}"
  done

  log "Copying source app bundle"
  rm -rf "$OUTPUT_APP"
  mkdir -p "$(dirname "$OUTPUT_APP")"
  ditto "$SOURCE_APP" "$OUTPUT_APP"

  output_frameworks_dir="${OUTPUT_APP}/Contents/Frameworks"
  output_resources_dir="${OUTPUT_APP}/Contents/Resources"
  output_unpacked_dir="${output_resources_dir}/app.asar.unpacked"

  log "Replacing Electron runtime binaries with x64 versions"
  copy_file "$electron_main" "${OUTPUT_APP}/Contents/MacOS/Codex"
  chmod +x "${OUTPUT_APP}/Contents/MacOS/Codex"

  copy_file \
    "${electron_frameworks_dir}/Electron Helper.app/Contents/MacOS/Electron Helper" \
    "${output_frameworks_dir}/Codex Helper.app/Contents/MacOS/Codex Helper"
  chmod +x "${output_frameworks_dir}/Codex Helper.app/Contents/MacOS/Codex Helper"

  copy_file \
    "${electron_frameworks_dir}/Electron Helper (GPU).app/Contents/MacOS/Electron Helper (GPU)" \
    "${output_frameworks_dir}/Codex Helper (GPU).app/Contents/MacOS/Codex Helper (GPU)"
  chmod +x "${output_frameworks_dir}/Codex Helper (GPU).app/Contents/MacOS/Codex Helper (GPU)"

  copy_file \
    "${electron_frameworks_dir}/Electron Helper (Plugin).app/Contents/MacOS/Electron Helper (Plugin)" \
    "${output_frameworks_dir}/Codex Helper (Plugin).app/Contents/MacOS/Codex Helper (Plugin)"
  chmod +x "${output_frameworks_dir}/Codex Helper (Plugin).app/Contents/MacOS/Codex Helper (Plugin)"

  copy_file \
    "${electron_frameworks_dir}/Electron Helper (Renderer).app/Contents/MacOS/Electron Helper (Renderer)" \
    "${output_frameworks_dir}/Codex Helper (Renderer).app/Contents/MacOS/Codex Helper (Renderer)"
  chmod +x "${output_frameworks_dir}/Codex Helper (Renderer).app/Contents/MacOS/Codex Helper (Renderer)"

  for framework in \
    "Electron Framework.framework" \
    "Mantle.framework" \
    "ReactiveObjC.framework" \
    "Squirrel.framework"
  do
    copy_dir "${electron_frameworks_dir}/${framework}" "${output_frameworks_dir}/${framework}"
  done

  log "Installing x64 native addons"
  copy_file "$BETTER_SQLITE3_NODE" "${output_unpacked_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  chmod +x "${output_unpacked_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node"

  copy_file "$PTY_NODE" "${output_unpacked_dir}/node_modules/node-pty/build/Release/pty.node"
  chmod +x "${output_unpacked_dir}/node_modules/node-pty/build/Release/pty.node"
  copy_file "$PTY_NODE" "${output_unpacked_dir}/node_modules/node-pty/prebuilds/darwin-x64/pty.node"
  chmod +x "${output_unpacked_dir}/node_modules/node-pty/prebuilds/darwin-x64/pty.node"

  copy_file "$SPAWN_HELPER" "${output_unpacked_dir}/node_modules/node-pty/build/Release/spawn-helper"
  chmod +x "${output_unpacked_dir}/node_modules/node-pty/build/Release/spawn-helper"
  copy_file "$SPAWN_HELPER" "${output_unpacked_dir}/node_modules/node-pty/prebuilds/darwin-x64/spawn-helper"
  chmod +x "${output_unpacked_dir}/node_modules/node-pty/prebuilds/darwin-x64/spawn-helper"

  if [[ "$SKIP_CLI_BUNDLE" -eq 0 ]]; then
    log "Bundling x64 codex CLI"
    copy_file "$CLI_BIN" "${output_resources_dir}/codex"
    chmod +x "${output_resources_dir}/codex"
    copy_file "$CLI_BIN" "${output_resources_dir}/bin/codex"
    chmod +x "${output_resources_dir}/bin/codex"
    copy_file "$CLI_BIN" "${output_unpacked_dir}/codex"
    chmod +x "${output_unpacked_dir}/codex"
    copy_file "$CLI_BIN" "${output_unpacked_dir}/bin/codex"
    chmod +x "${output_unpacked_dir}/bin/codex"
  else
    log "Skipping bundled CLI"
    rm -f "${output_resources_dir}/codex"
    rm -f "${output_unpacked_dir}/codex"
  fi

  if [[ -n "$SPARKLE_NODE" ]]; then
    log "Installing x64 sparkle.node"
    copy_file "$SPARKLE_NODE" "${output_resources_dir}/native/sparkle.node"
    chmod +x "${output_resources_dir}/native/sparkle.node"
    copy_file "$SPARKLE_NODE" "${output_unpacked_dir}/native/sparkle.node"
    chmod +x "${output_unpacked_dir}/native/sparkle.node"
  else
    log "Removing sparkle.node (auto-update disabled)"
    rm -f "${output_resources_dir}/native/sparkle.node"
    rm -f "${output_unpacked_dir}/native/sparkle.node"
  fi

  log "Removing stale signatures and quarantine metadata"
  find "$OUTPUT_APP" -name _CodeSignature -type d -prune -exec rm -rf {} +
  find "$OUTPUT_APP" -exec xattr -c {} + >/dev/null 2>&1 || true

  log "Ad-hoc signing rebuilt app"
  codesign --force --deep --sign - "$OUTPUT_APP"
  log "Verifying signature"
  codesign --verify --deep --strict "$OUTPUT_APP"

  if [[ "$SKIP_CLI_BUNDLE" -eq 1 ]]; then
    printf '\nCLI was not bundled. Launch with:\n'
    printf '  CODEX_CLI_PATH=/absolute/path/to/intel/codex open %q\n' "$OUTPUT_APP"
  fi
}

make_dmg() {
  local source_app="$1"
  local output_dmg="$2"
  local staging_dir="${REPO_ROOT}/.build/dmg-staging"
  local tmp_dmg="${REPO_ROOT}/.build/Codex-Intel.rw.dmg"
  local mount_point=""
  local attach_output=""
  local app_name
  local staging_size_mb
  local window_right window_bottom

  require_command hdiutil
  require_command ditto
  require_command osascript
  require_dir "$source_app"

  mkdir -p "$(dirname "$output_dmg")"
  mkdir -p "$(dirname "$staging_dir")"
  mkdir -p "$(dirname "$tmp_dmg")"
  rm -rf "$staging_dir"
  mkdir -p "$staging_dir"
  rm -f "$tmp_dmg"

  app_name="$(basename "$source_app")"
  ditto "$source_app" "${staging_dir}/${app_name}"
  ln -s /Applications "${staging_dir}/Applications"

  staging_size_mb="$(du -sm "$staging_dir" | awk '{print $1 + 96}')"
  log "Creating writable DMG template"
  hdiutil create \
    -size "${staging_size_mb}m" \
    -fs HFS+ \
    -volname "$VOLNAME" \
    -ov \
    "$tmp_dmg" >/dev/null

  attach_output="$(hdiutil attach "$tmp_dmg" -nobrowse -noverify)"
  mount_point="$(printf '%s\n' "$attach_output" | awk 'match($0,/\/Volumes\/.*/){print substr($0, RSTART, RLENGTH); exit}')"
  [[ -n "$mount_point" ]] || die "Failed to mount temporary dmg"
  trap 'if [[ -n "${mount_point:-}" ]]; then hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true; fi' EXIT

  log "Copying app into mounted DMG"
  rm -rf "${mount_point:?}/${app_name}" "${mount_point:?}/Applications"
  ditto "$source_app" "${mount_point}/${app_name}"
  ln -s /Applications "${mount_point}/Applications"

  window_right=$((DMG_WINDOW_LEFT + DMG_WINDOW_WIDTH))
  window_bottom=$((DMG_WINDOW_TOP + DMG_WINDOW_HEIGHT))

  log "Applying Finder layout"
  osascript >/dev/null <<EOF || true
tell application "Finder"
  tell disk "${VOLNAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {${DMG_WINDOW_LEFT}, ${DMG_WINDOW_TOP}, ${window_right}, ${window_bottom}}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set position of item "${app_name}" of container window to {${DMG_APP_ICON_X}, ${DMG_APP_ICON_Y}}
    set position of item "Applications" of container window to {${DMG_APPS_ICON_X}, ${DMG_APPS_ICON_Y}}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
EOF

  sync
  hdiutil detach "$mount_point" >/dev/null
  mount_point=""
  trap - EXIT

  log "Creating compressed DMG: $output_dmg"
  rm -f "$output_dmg"
  hdiutil convert "$tmp_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$output_dmg" >/dev/null

  rm -rf "$staging_dir"
  rm -f "$tmp_dmg"
}

# Defaults
SOURCE_APP=""
SOURCE_DMG=""
DMG_SOURCE_APP=""
OUTPUT_APP="${REPO_ROOT}/dist/Codex-Intel.app"
OUTPUT_DMG="${REPO_ROOT}/dist/Codex-Intel.dmg"
WORKDIR="${REPO_ROOT}/.build/codex-intel-build"

ELECTRON_VERSION="40.0.0"
BETTER_SQLITE3_VERSION="12.5.0"
NODE_PTY_VERSION="1.1.0"

VOLNAME="Codex Intel"
DMG_WINDOW_WIDTH=840
DMG_WINDOW_HEIGHT=520
DMG_WINDOW_LEFT=100
DMG_WINDOW_TOP=100
DMG_APP_ICON_X=240
DMG_APP_ICON_Y=260
DMG_APPS_ICON_X=650
DMG_APPS_ICON_Y=260

SKIP_BUILD=0
FORCE_CLEAN=0
SKIP_CLI_BUNDLE=0

RUN_BUILD=1
RUN_REPACKAGE=1
RUN_DMG=0
MODE_EXPLICIT=0

CLI_BIN=""
SPARKLE_NODE=""

ELECTRON_APP=""
BETTER_SQLITE3_NODE=""
PTY_NODE=""
SPAWN_HELPER=""
SOURCE_RESOLVED=0

WANT_APP=0
WANT_DMG=0
OUTPUT_FLAG_SET=0
TEMP_OUTPUT_APP=""
TEMP_APP_CREATED=0

if [[ -f "${REPO_ROOT}/Codex.dmg" ]]; then
  SOURCE_DMG="${REPO_ROOT}/Codex.dmg"
fi

if [[ $# -eq 0 ]]; then
  usage
  print_quick_help
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)
      MODE_EXPLICIT=1
      RUN_BUILD=1
      RUN_REPACKAGE=0
      RUN_DMG=0
      shift
      ;;
    --repackage-only)
      MODE_EXPLICIT=1
      RUN_BUILD=0
      RUN_REPACKAGE=1
      shift
      ;;
    --dmg-only)
      MODE_EXPLICIT=1
      RUN_BUILD=0
      RUN_REPACKAGE=0
      RUN_DMG=1
      shift
      ;;
    --app)
      WANT_APP=1
      OUTPUT_FLAG_SET=1
      shift
      ;;
    --source-app)
      SOURCE_APP="${2:-}"
      shift 2
      ;;
    --source-dmg)
      SOURCE_DMG="${2:-}"
      shift 2
      ;;
    --dmg-source-app)
      DMG_SOURCE_APP="${2:-}"
      shift 2
      ;;
    --output-app)
      OUTPUT_APP="${2:-}"
      shift 2
      ;;
    --output-dmg)
      OUTPUT_DMG="${2:-}"
      shift 2
      ;;
    --workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    --dmg)
      WANT_DMG=1
      OUTPUT_FLAG_SET=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --force-clean)
      FORCE_CLEAN=1
      shift
      ;;
    --electron-version)
      ELECTRON_VERSION="${2:-}"
      shift 2
      ;;
    --better-sqlite3-version)
      BETTER_SQLITE3_VERSION="${2:-}"
      shift 2
      ;;
    --node-pty-version)
      NODE_PTY_VERSION="${2:-}"
      shift 2
      ;;
    --cli-bin)
      CLI_BIN="${2:-}"
      shift 2
      ;;
    --skip-cli-bundle)
      SKIP_CLI_BUNDLE=1
      shift
      ;;
    --sparkle-node)
      SPARKLE_NODE="${2:-}"
      shift 2
      ;;
    --volname)
      VOLNAME="${2:-}"
      shift 2
      ;;
    --window-width)
      DMG_WINDOW_WIDTH="${2:-}"
      shift 2
      ;;
    --window-height)
      DMG_WINDOW_HEIGHT="${2:-}"
      shift 2
      ;;
    --window-left)
      DMG_WINDOW_LEFT="${2:-}"
      shift 2
      ;;
    --window-top)
      DMG_WINDOW_TOP="${2:-}"
      shift 2
      ;;
    --app-icon-x)
      DMG_APP_ICON_X="${2:-}"
      shift 2
      ;;
    --app-icon-y)
      DMG_APP_ICON_Y="${2:-}"
      shift 2
      ;;
    --apps-icon-x)
      DMG_APPS_ICON_X="${2:-}"
      shift 2
      ;;
    --apps-icon-y)
      DMG_APPS_ICON_Y="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ "$OUTPUT_FLAG_SET" -eq 0 ]]; then
  WANT_DMG=1
fi

if [[ "$MODE_EXPLICIT" -eq 0 ]]; then
  RUN_BUILD=1
  RUN_REPACKAGE=1
  RUN_DMG="$WANT_DMG"
fi

if [[ "$RUN_BUILD" -eq 1 && "$SKIP_BUILD" -eq 1 ]]; then
  RUN_BUILD=0
fi

if [[ "$RUN_REPACKAGE" -eq 1 && "$WANT_APP" -eq 0 && "$RUN_DMG" -eq 1 && "$MODE_EXPLICIT" -eq 0 ]]; then
  TEMP_OUTPUT_APP="${REPO_ROOT}/.build/tmp/Codex-Intel.app"
  OUTPUT_APP="$TEMP_OUTPUT_APP"
fi

if [[ "$RUN_REPACKAGE" -eq 1 ]]; then
  ensure_source_app
fi

if [[ "$RUN_BUILD" -eq 1 ]]; then
  log "Preparing Intel artifacts"
  prepare_artifacts
fi

if [[ "$RUN_REPACKAGE" -eq 1 ]]; then
  log "Repackaging app"
  repackage_app
  if [[ -n "$TEMP_OUTPUT_APP" ]]; then
    TEMP_APP_CREATED=1
  fi
fi

if [[ "$RUN_DMG" -eq 1 ]]; then
  if [[ -z "$DMG_SOURCE_APP" ]]; then
    if [[ "$RUN_REPACKAGE" -eq 1 ]]; then
      DMG_SOURCE_APP="$OUTPUT_APP"
    elif [[ -n "$SOURCE_APP" ]]; then
      DMG_SOURCE_APP="$SOURCE_APP"
    else
      DMG_SOURCE_APP="$OUTPUT_APP"
    fi
  fi
  log "Creating dmg"
  make_dmg "$DMG_SOURCE_APP" "$OUTPUT_DMG"
fi

if [[ "$TEMP_APP_CREATED" -eq 1 ]]; then
  rm -rf "$TEMP_OUTPUT_APP"
fi

log "Completed"
