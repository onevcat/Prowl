#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

GHOSTTY_REPOSITORY="${PROWL_GHOSTTY_ARTIFACT_REPOSITORY:-onevcat/ghostty}"
GHOSTTY_ARTIFACT_FLAVOR="${PROWL_GHOSTTY_ARTIFACT_FLAVOR:-prowl-v1}"
CHECKSUMS_FILE="${PROWL_GHOSTTY_CHECKSUMS_FILE:-$SCRIPT_DIR/ghosttykit-checksums.txt}"
VALIDATOR="${PROWL_GHOSTTY_ARTIFACT_VALIDATOR:-$SCRIPT_DIR/validate-ghosttykit-artifacts.py}"

XCFRAMEWORK_PATH="$PROJECT_DIR/Frameworks/GhosttyKit.xcframework"
GHOSTTY_RESOURCE_PATH="$PROJECT_DIR/Resources/ghostty"
TERMINFO_RESOURCE_PATH="$PROJECT_DIR/Resources/terminfo"
GHOSTTY_HASH_FILE="$PROJECT_DIR/.ghostty_hash"
GHOSTTY_BUILD_STAMP="$PROJECT_DIR/.ghostty_build_stamp"

# A local bridge build is intentionally opt-in; never label it as the pinned upstream artifact.
if [[ -n "${PROWL_GHOSTTY_SOURCE_DIR:-}" ]]; then
  source_dir="$(cd "$PROWL_GHOSTTY_SOURCE_DIR" && pwd)"
  framework="$source_dir/macos/GhosttyKit.xcframework"
  header="$framework/macos-arm64/Headers/ghostty.h"
  if [[ ! -f "$header" ]] || ! grep -q 'ghostty_surface_read_snapshot' "$header"; then
    echo "error: Build the mirror bridge XCFramework in $source_dir first." >&2
    exit 1
  fi
  mkdir -p "$PROJECT_DIR/Frameworks" "$GHOSTTY_RESOURCE_PATH" "$TERMINFO_RESOURCE_PATH"
  rsync -a --delete "$framework/" "$XCFRAMEWORK_PATH/"
  rsync -a --delete "$source_dir/zig-out/share/ghostty/" "$GHOSTTY_RESOURCE_PATH/"
  rsync -a --delete "$source_dir/zig-out/share/terminfo/" "$TERMINFO_RESOURCE_PATH/"
  printf 'local:%s\n' "$(git -C "$source_dir" rev-parse HEAD)" > "$GHOSTTY_HASH_FILE"
  exit 0
fi

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

lookup_checksums() {
  local ghostty_sha="$1"
  awk -v sha="$ghostty_sha" '
    $1 == sha {
      print $2 " " $3
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$CHECKSUMS_FILE"
}

pinned_ghostty_sha() {
  git rev-parse HEAD:ThirdParty/ghostty
}

artifacts_exist() {
  [[ -d "$XCFRAMEWORK_PATH" && -d "$GHOSTTY_RESOURCE_PATH" && -d "$TERMINFO_RESOURCE_PATH" ]]
}

stamp_matches() {
  [[ -f "$GHOSTTY_HASH_FILE" ]] && [[ "$(cat "$GHOSTTY_HASH_FILE")" == "$GHOSTTY_SHA" ]]
}

refresh_archive_index() {
  local archive="$XCFRAMEWORK_PATH/macos-arm64_x86_64/libghostty.a"
  if [[ ! -f "$archive" ]]; then
    return 0
  fi

  if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun is required to refresh libghostty archive index." >&2
    exit 1
  fi

  local ranlib
  ranlib="$(xcrun --find ranlib)"
  "$ranlib" "$archive"
}

install_artifacts() {
  local xcframework_archive="$1"
  local resources_archive="$2"
  local tmp_extract="$3"

  mkdir -p "$tmp_extract/xcframework" "$tmp_extract/resources" "$PROJECT_DIR/Frameworks" "$PROJECT_DIR/Resources"

  tar -xzf "$xcframework_archive" -C "$tmp_extract/xcframework"
  tar -xzf "$resources_archive" -C "$tmp_extract/resources"

  if [[ ! -d "$tmp_extract/xcframework/GhosttyKit.xcframework" ]]; then
    echo "error: xcframework archive did not contain GhosttyKit.xcframework" >&2
    exit 1
  fi
  if [[ ! -d "$tmp_extract/resources/ghostty" || ! -d "$tmp_extract/resources/terminfo" ]]; then
    echo "error: resources archive did not contain ghostty and terminfo directories" >&2
    exit 1
  fi

  rm -rf "$XCFRAMEWORK_PATH" "$GHOSTTY_RESOURCE_PATH" "$TERMINFO_RESOURCE_PATH"
  mv "$tmp_extract/xcframework/GhosttyKit.xcframework" "$XCFRAMEWORK_PATH"
  mv "$tmp_extract/resources/ghostty" "$GHOSTTY_RESOURCE_PATH"
  mv "$tmp_extract/resources/terminfo" "$TERMINFO_RESOURCE_PATH"

  refresh_archive_index
  printf '%s\n' "$GHOSTTY_SHA" > "$GHOSTTY_HASH_FILE"
  touch "$GHOSTTY_BUILD_STAMP"
}

try_fetch_prebuilt() {
  if [[ "${PROWL_GHOSTTY_NO_PREBUILT:-0}" == "1" ]]; then
    echo "GhosttyKit prebuilt download disabled; falling back to local build."
    return 2
  fi

  if [[ ! -f "$CHECKSUMS_FILE" ]]; then
    echo "Missing GhosttyKit checksum manifest; falling back to local build." >&2
    return 2
  fi

  local checksums expected_xcframework_sha expected_resources_sha
  if ! checksums="$(lookup_checksums "$GHOSTTY_SHA" 2>/dev/null)"; then
    echo "No pinned GhosttyKit artifact for ${GHOSTTY_SHA:0:12}; falling back to local build."
    return 2
  fi
  read -r expected_xcframework_sha expected_resources_sha <<< "$checksums"

  local tag="xcframework-$GHOSTTY_SHA-$GHOSTTY_ARTIFACT_FLAVOR"
  local base_url="https://github.com/$GHOSTTY_REPOSITORY/releases/download/$tag"
  local tmp_dir="$PROJECT_DIR/.ghostty-download.$$"
  local xcframework_archive="$tmp_dir/GhosttyKit.xcframework.tar.gz"
  local resources_archive="$tmp_dir/GhosttyKit-resources.tar.gz"

  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  trap 'rm -rf "$tmp_dir"' RETURN

  echo "Fetching prebuilt GhosttyKit artifacts for ${GHOSTTY_SHA:0:12}..."
  if ! curl -fsSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 --retry-all-errors \
    -o "$xcframework_archive" "$base_url/GhosttyKit.xcframework.tar.gz"; then
    echo "Prebuilt GhosttyKit.xcframework unavailable; falling back to local build."
    return 2
  fi
  if ! curl -fsSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 --retry-all-errors \
    -o "$resources_archive" "$base_url/GhosttyKit-resources.tar.gz"; then
    echo "Prebuilt GhosttyKit resources unavailable; falling back to local build."
    return 2
  fi

  local actual_xcframework_sha actual_resources_sha
  actual_xcframework_sha="$(hash_file "$xcframework_archive")"
  actual_resources_sha="$(hash_file "$resources_archive")"

  if [[ "$actual_xcframework_sha" != "$expected_xcframework_sha" ]]; then
    echo "error: GhosttyKit.xcframework checksum mismatch." >&2
    echo "  expected: $expected_xcframework_sha" >&2
    echo "  actual:   $actual_xcframework_sha" >&2
    exit 1
  fi
  if [[ "$actual_resources_sha" != "$expected_resources_sha" ]]; then
    echo "error: GhosttyKit resources checksum mismatch." >&2
    echo "  expected: $expected_resources_sha" >&2
    echo "  actual:   $actual_resources_sha" >&2
    exit 1
  fi

  python3 "$VALIDATOR" xcframework "$xcframework_archive"
  python3 "$VALIDATOR" resources "$resources_archive"

  install_artifacts "$xcframework_archive" "$resources_archive" "$tmp_dir/extract"
  echo "Installed prebuilt GhosttyKit artifacts for ${GHOSTTY_SHA:0:12}."
}

GHOSTTY_SHA="$(pinned_ghostty_sha)"

if artifacts_exist && stamp_matches; then
  echo "GhosttyKit up-to-date (SHA unchanged)"
  exit 0
fi

echo "Syncing GhosttyKit for submodule $GHOSTTY_SHA"

previous_sha=""
if [[ -f "$GHOSTTY_HASH_FILE" ]]; then
  previous_sha="$(cat "$GHOSTTY_HASH_FILE")"
fi

if try_fetch_prebuilt; then
  if [[ "$previous_sha" != "$GHOSTTY_SHA" ]]; then
    rm -rf ~/Library/Developer/Xcode/DerivedData/supacode-*
    echo "Cleared Xcode DerivedData for ghostty header/module changes"
  fi
  exit 0
fi

exit 2
