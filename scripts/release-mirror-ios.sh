#!/usr/bin/env bash
# Archive the iOS mirror app (Prowl Mirror) and publish it to TestFlight.
#
# Usage: ./scripts/release-mirror-ios.sh [--export-only]
#
#   --export-only   Archive and export an IPA to build/mirror-ios/export without uploading.
#
# xcodebuild archives and exports the IPA. `asc` (https://asccli.sh) uploads it, waits for
# App Store Connect to process it, writes the What to Test notes, and adds it to a beta group.
# `asc` uses its own credentials (`asc auth login`); xcodebuild signs with the Apple ID that is
# signed in to Xcode, and creates the distribution certificate and profile when they are missing.
#
# Versioning follows the Mac app's CalVer: MARKETING_VERSION is the local date (YYYY.M.D) and
# CURRENT_PROJECT_VERSION is the local time (YYYYMMDDHHMM), so each upload gets a larger build.
# The values go to xcodebuild only; nothing is committed or tagged.
#
# Environment variables:
#   MIRROR_IOS_VERSION           Overrides the marketing version (YYYY.M.D)
#   MIRROR_IOS_BUILD             Overrides the build number (integer)
#   MIRROR_IOS_TEAM_ID           Overrides DEVELOPMENT_TEAM from Config/Local.xcconfig
#   MIRROR_IOS_ASC_APP_ID        App Store Connect app ID (default: Prowl Mirror)
#   MIRROR_IOS_TESTFLIGHT_GROUP  Beta group names or IDs, comma-separated (default: Internal);
#                                empty uploads the build without adding it to a group
#   MIRROR_IOS_TEST_NOTES        What to Test notes (default: the commit and the recent
#                                commits that changed the mirror client)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

log() { echo "[mirror-ios] $*"; }
die() {
  echo "[mirror-ios] error: $*" >&2
  exit 1
}

UPLOAD=1
case "${1:-}" in
  "") ;;
  --export-only) UPLOAD=0 ;;
  *) die "unknown argument: $1 (usage: $0 [--export-only])" ;;
esac

PROJECT="$PROJECT_DIR/Mirror/iOS/ProwlMirror-iOS.xcodeproj"
SCHEME="ProwlMirror-iOS"
OUTPUT_DIR="$PROJECT_DIR/build/mirror-ios"
ARCHIVE_PATH="$OUTPUT_DIR/ProwlMirror-iOS.xcarchive"
EXPORT_PATH="$OUTPUT_DIR/export"
EXPORT_OPTIONS="$OUTPUT_DIR/ExportOptions.plist"
IPA_PATH="$EXPORT_PATH/ProwlMirror-iOS.ipa"
APP_ID="${MIRROR_IOS_ASC_APP_ID:-6831901271}"
GROUP="${MIRROR_IOS_TESTFLIGHT_GROUP-Internal}"
# The sources that go into the app; the notes list the commits that changed them.
CLIENT_PATHS=(Mirror/iOS Mirror/Shared Mirror/Fixtures)

# ── Preflight ────────────────────────────────────────────────────────────────

# A build on App Store Connect must map to one commit.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  die "the working tree has uncommitted changes; commit or stash them first"
fi
COMMIT="$(git rev-parse --short HEAD)"

VERSION="${MIRROR_IOS_VERSION:-$(date +%Y.%-m.%-d)}"
BUILD="${MIRROR_IOS_BUILD:-$(date +%Y%m%d%H%M)}"
# iOS accepts at most three components in CFBundleShortVersionString, so the Mac app's
# same-day suffix (YYYY.M.D.N) is not allowed here.
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}$ ]] || die "MIRROR_IOS_VERSION must be YYYY.M.D, got $VERSION"
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "MIRROR_IOS_BUILD must be an integer, got $BUILD"

if [[ "$UPLOAD" -eq 1 ]]; then
  command -v asc >/dev/null || die "asc is not installed; run: brew install asc"
  # Fail before the archive, not after it.
  asc apps view --id "$APP_ID" --output json >/dev/null 2>&1 \
    || die "asc cannot read app $APP_ID; check \`asc auth status\` and MIRROR_IOS_ASC_APP_ID"
fi

log "generating the project"
mise exec -- tuist generate --path Mirror/iOS --no-open >/dev/null

TEAM_ARGS=()
if [[ -n "${MIRROR_IOS_TEAM_ID:-}" ]]; then
  TEAM_ARGS=(DEVELOPMENT_TEAM="$MIRROR_IOS_TEAM_ID")
fi
TEAM_ID="$(
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings \
    ${TEAM_ARGS[@]+"${TEAM_ARGS[@]}"} 2>/dev/null \
    | awk -F' = ' '$1 ~ /^ +DEVELOPMENT_TEAM$/ {print $2; exit}'
)"
[[ -n "$TEAM_ID" ]] || die "no DEVELOPMENT_TEAM; set it in Config/Local.xcconfig or MIRROR_IOS_TEAM_ID"

log "version $VERSION ($BUILD), team $TEAM_ID, commit $COMMIT"

# ── Archive and export ───────────────────────────────────────────────────────

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$OUTPUT_DIR"

log "archiving"
if ! xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE_PATH" -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  ${TEAM_ARGS[@]+"${TEAM_ARGS[@]}"} \
  2>&1 | tee "$OUTPUT_DIR/archive.log" | mise exec -- xcsift -qw --format toon; then
  die "archive failed; see $OUTPUT_DIR/archive.log"
fi

cat >"$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF

log "exporting the IPA"
if ! xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  2>&1 | tee "$OUTPUT_DIR/export.log" | mise exec -- xcsift -qw --format toon; then
  die "export failed; see $OUTPUT_DIR/export.log"
fi
[[ -f "$IPA_PATH" ]] || die "the export did not write $IPA_PATH"

if [[ "$UPLOAD" -eq 0 ]]; then
  log "exported $VERSION ($BUILD) from $COMMIT to $IPA_PATH"
  exit 0
fi

# ── Publish to TestFlight ────────────────────────────────────────────────────

if [[ -n "${MIRROR_IOS_TEST_NOTES:-}" ]]; then
  NOTES="$MIRROR_IOS_TEST_NOTES"
else
  NOTES="Commit $COMMIT

Recent changes:
$(git log -n 15 --no-merges --format='- %s' HEAD -- "${CLIENT_PATHS[@]}")"
fi
# App Store Connect limits What to Test to 4000 characters.
NOTES="${NOTES:0:4000}"

PUBLISH_ARGS=(--app "$APP_ID" --ipa "$IPA_PATH" --version "$VERSION" --wait --output table)
if [[ -n "$GROUP" ]]; then
  PUBLISH_ARGS+=(--group "$GROUP" --test-notes "$NOTES" --locale en-US)
  log "uploading and adding the build to TestFlight group(s): $GROUP"
else
  PUBLISH_ARGS+=(--upload-only)
  log "uploading without a TestFlight group"
fi
asc publish testflight "${PUBLISH_ARGS[@]}" || die "asc publish testflight failed"

log "published $VERSION ($BUILD) from $COMMIT to TestFlight"
