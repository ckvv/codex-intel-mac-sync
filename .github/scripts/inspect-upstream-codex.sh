#!/usr/bin/env bash

set -euo pipefail

SOURCE_URL="${1:-}"
OUTPUT_DMG="${2:-}"

if [[ -z "$SOURCE_URL" || -z "$OUTPUT_DMG" ]]; then
  printf 'Usage: %s <source-url> <output-dmg>\n' "$(basename "$0")" >&2
  exit 1
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

write_output() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
}

sanitize_token() {
  printf '%s' "$1" | tr -cs '[:alnum:]._-' '-'
}

require_command curl
require_command hdiutil
require_command defaults
require_command shasum
require_command awk
require_command find

mkdir -p "$(dirname "$OUTPUT_DMG")"
rm -f "$OUTPUT_DMG"

curl \
  --fail \
  --location \
  --retry 3 \
  --retry-all-errors \
  --output "$OUTPUT_DMG" \
  "$SOURCE_URL"

sha256="$(shasum -a 256 "$OUTPUT_DMG" | awk '{print $1}')"
short_sha="${sha256:0:12}"

attach_output="$(hdiutil attach "$OUTPUT_DMG" -readonly -nobrowse 2>/dev/null || true)"
mount_point="$(printf '%s\n' "$attach_output" | awk 'match($0,/\/Volumes\/.*/){print substr($0, RSTART, RLENGTH); exit}')"

if [[ -z "$mount_point" ]]; then
  printf 'Failed to mount dmg: %s\n' "$OUTPUT_DMG" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${mount_point:-}" ]]; then
    hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

app_path="$(find "$mount_point" -maxdepth 1 -type d -name '*.app' | head -n 1 || true)"

if [[ -z "$app_path" ]]; then
  printf 'No .app bundle found inside: %s\n' "$OUTPUT_DMG" >&2
  exit 1
fi

info_plist="${app_path}/Contents/Info.plist"
version="$(defaults read "$info_plist" CFBundleShortVersionString)"
build="$(defaults read "$info_plist" CFBundleVersion)"
app_name="$(basename "$app_path")"

safe_version="$(sanitize_token "$version")"
safe_build="$(sanitize_token "$build")"
release_tag="codex-desktop-v${safe_version}-${safe_build}-${short_sha}"
release_name="Codex Intel ${version} (${build})"
asset_name="Codex-Intel-${safe_version}-${safe_build}-${short_sha}.dmg"

write_output source_url "$SOURCE_URL"
write_output source_dmg "$OUTPUT_DMG"
write_output source_sha256 "$sha256"
write_output source_sha12 "$short_sha"
write_output source_app_name "$app_name"
write_output version "$version"
write_output build "$build"
write_output release_tag "$release_tag"
write_output release_name "$release_name"
write_output asset_name "$asset_name"
