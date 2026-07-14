#!/bin/bash
set -euo pipefail

# Builds the durable fork without committing Palmier's runtime configuration.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
CONFIG_APP="${PALMIER_CONFIG_APP:-/Applications/PalmierPro.app}"
OUTPUT_DIR="${PALMIER_CUSTOM_OUTPUT_DIR:-$ROOT/.build/custom}"

case "$CONFIG" in
  debug|release) ;;
  *) echo "usage: scripts/build-custom.sh [debug|release]" >&2; exit 1 ;;
esac
case "$OUTPUT_DIR" in
  ""|/|"$HOME") echo "error: unsafe PALMIER_CUSTOM_OUTPUT_DIR: $OUTPUT_DIR" >&2; exit 1 ;;
esac

read_config() {
  local environment_key="$1" plist_key="$2" value=""
  if [ -n "${!environment_key:-}" ]; then
    return
  fi
  if [ -f "$CONFIG_APP/Contents/Info.plist" ]; then
    value="$(/usr/libexec/PlistBuddy -c "Print :$plist_key" "$CONFIG_APP/Contents/Info.plist" 2>/dev/null || true)"
  fi
  if [ -z "$value" ]; then
    echo "error: $environment_key is unset and $plist_key is unavailable in $CONFIG_APP" >&2
    exit 1
  fi
  export "$environment_key=$value"
}

read_config CLERK_PUBLISHABLE_KEY PalmierClerkPublishableKey
read_config CONVEX_DEPLOYMENT_URL PalmierConvexDeploymentURL
read_config CONVEX_HTTP_URL PalmierConvexHttpURL

prefetch_speech_core() {
  local url checksum cache_dir cache_name cache_file temp_file actual
  url="https://github.com/soniqo/speech-core/releases/download/v0.0.6/SpeechCore.xcframework.zip"
  checksum="aca6733cd04b873e1f7a428993e8d4f23ffceed42f7507cd1196c0b89d34f170"
  cache_dir="${SWIFTPM_ARTIFACT_CACHE:-$HOME/Library/Caches/org.swift.swiftpm/artifacts}"
  cache_name="$(printf '%s' "$url" | sed 's/[^A-Za-z0-9]/_/g')"
  cache_file="$cache_dir/$cache_name"

  if [ -f "$cache_file" ]; then
    actual="$(shasum -a 256 "$cache_file" | awk '{print $1}')"
    [ "$actual" = "$checksum" ] && return
  fi

  mkdir -p "$cache_dir"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/palmier-speech-core.XXXXXX")"
  if ! curl --fail --location --retry 3 --silent --show-error "$url" --output "$temp_file"; then
    rm -f "$temp_file"
    echo "error: failed to download the bundled SpeechCore artifact" >&2
    exit 1
  fi
  actual="$(shasum -a 256 "$temp_file" | awk '{print $1}')"
  if [ "$actual" != "$checksum" ]; then
    rm -f "$temp_file"
    echo "error: bundled SpeechCore checksum mismatch" >&2
    exit 1
  fi
  mv "$temp_file" "$cache_file"
}

# SwiftPM can stall while fetching this conditional binary target. Seed its
# checksum-verified artifact cache so clean-Mac builds are deterministic.
prefetch_speech_core

"$ROOT/scripts/bundle.sh" "$CONFIG"

SOURCE_APP="$ROOT/.build/PalmierPro.app"
CUSTOM_APP="$OUTPUT_DIR/PalmierPro-Custom.app"
CUSTOM_ZIP="$OUTPUT_DIR/PalmierPro-Custom.zip"
CHECKSUM="$CUSTOM_ZIP.sha256"
REVISION="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
UPSTREAM_REVISION="$(git -C "$ROOT" merge-base HEAD upstream/main 2>/dev/null || git -C "$ROOT" rev-parse HEAD)"
UPSTREAM_REVISION="${UPSTREAM_REVISION:0:12}"

mkdir -p "$OUTPUT_DIR"
rm -rf "$CUSTOM_APP"
rm -f "$CUSTOM_ZIP" "$CHECKSUM"
/usr/bin/ditto "$SOURCE_APP" "$CUSTOM_APP"

set_plist() {
  local key="$1" type="$2" value="$3"
  /usr/libexec/PlistBuddy -c "Delete :$key" "$CUSTOM_APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$CUSTOM_APP/Contents/Info.plist"
}

set_plist PalmierForkBuild bool true
set_plist PalmierForkName string "BrowningL custom integration"
set_plist PalmierForkRevision string "$REVISION"
set_plist PalmierUpstreamRevision string "$UPSTREAM_REVISION"
set_plist SUEnableAutomaticChecks bool false

codesign --force --deep --sign - "$CUSTOM_APP"
codesign --verify --deep --strict "$CUSTOM_APP"

if [ "$(/usr/libexec/PlistBuddy -c 'Print :PalmierForkBuild' "$CUSTOM_APP/Contents/Info.plist")" != "true" ]; then
  echo "error: custom-build marker missing" >&2
  exit 1
fi
if [ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$CUSTOM_APP/Contents/Info.plist")" != "false" ]; then
  echo "error: official automatic updates are still enabled" >&2
  exit 1
fi
if ! lipo -archs "$CUSTOM_APP/Contents/MacOS/PalmierPro" | grep -qw arm64; then
  echo "error: custom app does not contain arm64" >&2
  exit 1
fi

for required in \
  "$CUSTOM_APP/Contents/Resources/Fonts" \
  "$CUSTOM_APP/Contents/Resources/Models" \
  "$CUSTOM_APP/Contents/Resources/palmier-pro.mcpb" \
  "$CUSTOM_APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"; do
  if [ ! -e "$required" ]; then
    echo "error: required runtime resource missing: $required" >&2
    exit 1
  fi
done
if ! find "$CUSTOM_APP/Contents/Resources" -maxdepth 1 -name '*.metallib' -print -quit | grep -q .; then
  echo "error: custom Metal effects library is missing" >&2
  exit 1
fi

/usr/bin/ditto -c -k --keepParent "$CUSTOM_APP" "$CUSTOM_ZIP"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$CUSTOM_ZIP")"
) > "$CHECKSUM"

echo "==> Durable custom build complete"
echo "   App: $CUSTOM_APP"
echo "   ZIP: $CUSTOM_ZIP"
echo "   SHA-256: $CHECKSUM"
echo "   Fork revision: $REVISION"
echo "   Upstream base: $UPSTREAM_REVISION"
