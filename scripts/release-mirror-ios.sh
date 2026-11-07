#!/usr/bin/env bash
# Archive the iOS mirror app (Prowl Mirror) and upload it to App Store Connect for TestFlight.
#
# Usage: ./scripts/release-mirror-ios.sh [--export-only]
#
#   --export-only   Archive and export an IPA to build/mirror-ios/export without uploading.
#
# Versioning follows the Mac app's CalVer: MARKETING_VERSION is the local date (YYYY.M.D) and
# CURRENT_PROJECT_VERSION is the local time (YYYYMMDDHHMM), so each upload gets a larger build.
# The values go to xcodebuild only; nothing is committed or tagged.
#
# Signing uses Xcode automatic signing with the team from Config/Local.xcconfig. Xcode creates the
# distribution certificate and the provisioning profile when they are missing.
#
# Environment variables (environment or Config/Secrets.env):
#   MIRROR_IOS_VERSION     Overrides the marketing version (YYYY.M.D)
#   MIRROR_IOS_BUILD       Overrides the build number (integer)
#   MIRROR_IOS_TEAM_ID     Overrides DEVELOPMENT_TEAM from Config/Local.xcconfig
#   PROWL_ASC_KEY_ID       App Store Connect API key ID
#   PROWL_ASC_ISSUER_ID    App Store Connect API key issuer ID
#   PROWL_ASC_KEY_PATH     Path to the AuthKey_<KEY_ID>.p8 file
#   The three PROWL_ASC_* values are optional. Without them, xcodebuild uses the Apple ID that
#   is signed in to Xcode (Settings > Accounts).
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

if [[ -f "$PROJECT_DIR/Config/Secrets.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_DIR/Config/Secrets.env"
  set +a
fi

PROJECT="$PROJECT_DIR/Mirror/iOS/ProwlMirror-iOS.xcodeproj"
SCHEME="ProwlMirror-iOS"
OUTPUT_DIR="$PROJECT_DIR/build/mirror-ios"
ARCHIVE_PATH="$OUTPUT_DIR/ProwlMirror-iOS.xcarchive"
EXPORT_PATH="$OUTPUT_DIR/export"
EXPORT_OPTIONS="$OUTPUT_DIR/ExportOptions.plist"

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

AUTH_ARGS=()
if [[ -n "${PROWL_ASC_KEY_ID:-}${PROWL_ASC_ISSUER_ID:-}${PROWL_ASC_KEY_PATH:-}" ]]; then
  [[ -n "${PROWL_ASC_KEY_ID:-}" && -n "${PROWL_ASC_ISSUER_ID:-}" && -n "${PROWL_ASC_KEY_PATH:-}" ]] \
    || die "set all of PROWL_ASC_KEY_ID, PROWL_ASC_ISSUER_ID and PROWL_ASC_KEY_PATH, or none of them"
  KEY_PATH="${PROWL_ASC_KEY_PATH/#\~/$HOME}"
  [[ -f "$KEY_PATH" ]] || die "PROWL_ASC_KEY_PATH does not exist: $KEY_PATH"
  AUTH_ARGS=(
    -authenticationKeyPath "$KEY_PATH"
    -authenticationKeyID "$PROWL_ASC_KEY_ID"
    -authenticationKeyIssuerID "$PROWL_ASC_ISSUER_ID"
  )
  log "authentication: App Store Connect API key $PROWL_ASC_KEY_ID"
else
  log "authentication: the Apple ID signed in to Xcode"
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

# ── Archive ──────────────────────────────────────────────────────────────────

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$OUTPUT_DIR"

log "archiving"
if ! xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  ${TEAM_ARGS[@]+"${TEAM_ARGS[@]}"} \
  2>&1 | tee "$OUTPUT_DIR/archive.log" | mise exec -- xcsift -qw --format toon; then
  die "archive failed; see $OUTPUT_DIR/archive.log"
fi

# ── Export or upload ─────────────────────────────────────────────────────────

if [[ "$UPLOAD" -eq 1 ]]; then DESTINATION="upload"; else DESTINATION="export"; fi
cat >"$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>$DESTINATION</string>
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

if [[ "$UPLOAD" -eq 1 ]]; then log "uploading to App Store Connect"; else log "exporting the IPA"; fi
if ! xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
  2>&1 | tee "$OUTPUT_DIR/export.log" | mise exec -- xcsift -qw --format toon; then
  die "export failed; see $OUTPUT_DIR/export.log"
fi

if [[ "$UPLOAD" -eq 1 ]]; then
  log "uploaded $VERSION ($BUILD) from $COMMIT; TestFlight shows it after App Store Connect processes it"
else
  log "exported $VERSION ($BUILD) from $COMMIT to $EXPORT_PATH"
fi
