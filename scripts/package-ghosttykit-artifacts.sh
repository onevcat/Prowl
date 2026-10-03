#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="${PROWL_GHOSTTY_ARTIFACT_DIST_DIR:-$PROJECT_DIR/dist/ghosttykit}"

XCFRAMEWORK_PATH="$PROJECT_DIR/App/Frameworks/GhosttyKit.xcframework"
GHOSTTY_RESOURCE_PATH="$PROJECT_DIR/App/Resources/ghostty"
TERMINFO_RESOURCE_PATH="$PROJECT_DIR/App/Resources/terminfo"

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

require_dir() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    echo "error: missing required directory: $path" >&2
    exit 1
  fi
}

require_dir "$XCFRAMEWORK_PATH"
require_dir "$GHOSTTY_RESOURCE_PATH"
require_dir "$TERMINFO_RESOURCE_PATH"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

XCFRAMEWORK_ARCHIVE="$DIST_DIR/GhosttyKit.xcframework.tar.gz"
RESOURCES_ARCHIVE="$DIST_DIR/GhosttyKit-resources.tar.gz"

(
  cd "$PROJECT_DIR/Frameworks"
  COPYFILE_DISABLE=1 tar czf "$XCFRAMEWORK_ARCHIVE" GhosttyKit.xcframework
)

(
  cd "$PROJECT_DIR/Resources"
  COPYFILE_DISABLE=1 tar czf "$RESOURCES_ARCHIVE" ghostty terminfo
)

python3 "$SCRIPT_DIR/validate-ghosttykit-artifacts.py" xcframework "$XCFRAMEWORK_ARCHIVE"
python3 "$SCRIPT_DIR/validate-ghosttykit-artifacts.py" resources "$RESOURCES_ARCHIVE"

GHOSTTY_SHA="$(git -C "$PROJECT_DIR" rev-parse HEAD:ThirdParty/ghostty)"
XCFRAMEWORK_SHA="$(hash_file "$XCFRAMEWORK_ARCHIVE")"
RESOURCES_SHA="$(hash_file "$RESOURCES_ARCHIVE")"

cat <<EOF
Artifact directory:
$DIST_DIR

Release tag:
xcframework-$GHOSTTY_SHA-prowl-v1

Assets:
$XCFRAMEWORK_ARCHIVE
$RESOURCES_ARCHIVE

Checksum manifest entry:
$GHOSTTY_SHA $XCFRAMEWORK_SHA $RESOURCES_SHA
EOF
