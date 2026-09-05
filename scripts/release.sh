#!/usr/bin/env bash
# Prowl release script: bump, build, sign, notarize, and publish.
#
# Usage: ./scripts/release.sh [VERSION]
#
# Prerequisites:
#   Run ./scripts/release-notes.sh first to generate and review
#   build/release-notes.md. This script will refuse to proceed without it.
#
# Environment variables:
#   APPLE_SIGNING_IDENTITY          Developer ID identity (auto-detected if unset)
#   APPLE_TEAM_ID                   Apple Team ID (inferred from identity if unset)
#   APPLE_NOTARY_KEYCHAIN_PROFILE   Keychain profile for notarytool (default: supacode-notary)
#   SPARKLE_PRIVATE_KEY_FILE        Path to EdDSA private key file (default: ~/.prowl-sparkle-private-key)
#   NETLIFY_BUILD_HOOK              Netlify Build Hook URL for Prowl-Site rebuild
#   SKIP_SENTRY                     Set to 1 to skip dSYM upload and Sentry release tracking
#   FORCE_RERELEASE                 Set to 1 to replace a version that already has a GitHub Release
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# Load .env if present (not committed to repo)
if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a
  source "$PROJECT_DIR/.env"
  set +a
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

origin_repo_from_remote() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  [[ -z "$remote_url" ]] && return 1
  local repo
  repo="$(echo "$remote_url" | sed -E 's#^(git@github.com:|ssh://git@github.com/|https://github.com/)##; s#\.git$##')"
  [[ "$repo" == */* ]] && echo "$repo" && return 0
  return 1
}

default_signing_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}'
}

team_id_from_identity() {
  local identity="$1"
  if [[ "$identity" =~ \(([A-Z0-9]{10})\)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

signing_identity_sha() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep "$1" | head -1 | awk '{print $2}'
}

log() { echo "[release] $*"; }
die() { echo "error: $*" >&2; exit 1; }

version_date_compact() {
  # Print the YYYYMMDD date encoded in a YYYY.M.DD[.N] version string.
  # Fails when the components do not form a real calendar date (BSD date
  # either rejects the input or normalizes it, so a round-trip mismatch
  # catches rollovers like 2026.2.30 -> 2026-03-02).
  local year month day compact roundtrip
  IFS='.' read -r year month day _ <<<"$1"
  compact="$(printf '%04d%02d%02d' "$((10#$year))" "$((10#$month))" "$((10#$day))")"
  roundtrip="$(date -j -f '%Y%m%d' "$compact" +%Y%m%d 2>/dev/null)" || return 1
  [[ "$roundtrip" == "$compact" ]] || return 1
  echo "$compact"
}

ensure_release_not_published() {
  # A GitHub Release for this tag means the version already shipped. Re-running
  # would delete and re-create the release and force-move the published tag, so
  # a mistyped old version must not silently clobber a live release.
  local repo="$1" tag="$2"
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    if [[ "${FORCE_RERELEASE:-}" != "1" ]]; then
      die "GitHub Release $tag already exists on $repo — refusing to overwrite a published release (set FORCE_RERELEASE=1 to replace it intentionally)"
    fi
    log "FORCE_RERELEASE=1 — existing release $tag will be replaced"
  fi
}

# ── Preflight ────────────────────────────────────────────────────────────────

log "preflight checks..."

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
for cmd in gh jq codesign xcrun create-dmg; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not found"
done
[[ -x "$PROJECT_DIR/bins/generate_appcast" ]] || die "bins/generate_appcast not found"

SENTRY_ENABLED=1
if [[ "${SKIP_SENTRY:-}" == "1" ]]; then
  SENTRY_ENABLED=0
  log "SKIP_SENTRY=1 set, dSYM upload and release tracking will be skipped"
elif ! command -v sentry-cli >/dev/null 2>&1; then
  SENTRY_ENABLED=0
  log "WARNING: sentry-cli not installed; dSYM upload will be skipped"
  log "         install:  brew install getsentry/tools/sentry-cli"
  log "         suppress: SKIP_SENTRY=1"
fi

if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is not clean — commit or stash changes first"
fi

# Releasing from a stale checkout starts the build-number monotonicity guard
# from an outdated CURRENT_PROJECT_VERSION and merges outdated appcast history,
# which can publish a Sparkle item that sorts below the live latest build.
log "checking checkout freshness against origin/main..."
git fetch --quiet origin || die "cannot fetch origin — network is required for a release"
git rev-parse --verify --quiet origin/main >/dev/null || die "origin/main not found — cannot verify checkout freshness"
if ! git merge-base --is-ancestor origin/main HEAD; then
  die "HEAD does not contain origin/main — sync your checkout (git pull) before releasing"
fi

REPO="${GH_REPO:-$(origin_repo_from_remote || true)}"
[[ -z "$REPO" ]] && REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
[[ -z "$REPO" ]] && die "cannot determine GitHub repository"

KEYCHAIN_PROFILE="${APPLE_NOTARY_KEYCHAIN_PROFILE:-supacode-notary}"
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-$(default_signing_identity || true)}"
[[ -z "$SIGNING_IDENTITY" ]] && die "no Developer ID Application identity found — set APPLE_SIGNING_IDENTITY"

TEAM_ID="${APPLE_TEAM_ID:-$(team_id_from_identity "$SIGNING_IDENTITY" || true)}"
[[ -z "$TEAM_ID" ]] && die "cannot determine Apple Team ID — set APPLE_TEAM_ID"

IDENTITY_SHA="$(signing_identity_sha "$SIGNING_IDENTITY")"
[[ -z "$IDENTITY_SHA" ]] && die "cannot find signing identity SHA for: $SIGNING_IDENTITY"

SPARKLE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$HOME/.prowl-sparkle-private-key}"
[[ -f "$SPARKLE_KEY_FILE" ]] || die "Sparkle private key not found: $SPARKLE_KEY_FILE"

NOTES_FILE="build/release-notes.md"
[[ -s "$NOTES_FILE" ]] || die "$NOTES_FILE not found — run release-notes.sh first"

# Section headings must be `### New` / `### Fixed` / `### Improved` so they
# render as <h3> on Prowl-Site (its CSS targets `:global(h3)`) and sit one
# level below the `## [VERSION]` header that this script prepends. Reject
# bold-paragraph pseudo-headings and `## …` headings — both render unstyled.
if bad_lines="$(grep -nE '^(\*\*(New|Fixed|Improved)\*\*|## (New|Fixed|Improved))[[:space:]]*$' "$NOTES_FILE")"; then
  echo "error: invalid section headings in $NOTES_FILE:" >&2
  echo "$bad_lines" | sed 's/^/  /' >&2
  die "use '### New' / '### Fixed' / '### Improved' (level-3 headings) instead"
fi

log "repository: $REPO"
log "signing identity: $SIGNING_IDENTITY"
log "team ID: $TEAM_ID"

# ── Version ──────────────────────────────────────────────────────────────────

if [[ -n "${1:-}" ]]; then
  VERSION="$1"
  if ! echo "$VERSION" | grep -qE '^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(\.[0-9]+)?$'; then
    die "VERSION must be in YYYY.M.DD or YYYY.M.DD.N format"
  fi
  VERSION_DATE="$(version_date_compact "$VERSION")" \
    || die "VERSION $VERSION does not encode a real calendar date"
  TODAY_COMPACT="$(date +%Y%m%d)"
  if (( VERSION_DATE > TODAY_COMPACT )); then
    die "VERSION $VERSION is dated in the future (today is $(date +%Y.%-m.%-d)) — refusing to publish a future-dated release"
  fi
  if (( VERSION_DATE < TODAY_COMPACT )); then
    log "note: VERSION $VERSION is dated before today ($(date +%Y.%-m.%-d))"
  fi
else
  VERSION="$(date +%Y.%-m.%-d)"
  suffix=1
  while git rev-parse "v$VERSION" >/dev/null 2>&1; do
    suffix=$((suffix + 1))
    VERSION="$(date +%Y.%-m.%-d).$suffix"
  done
fi

TAG="v$VERSION"

ensure_release_not_published "$REPO" "$TAG"

BUILD="$(date +%Y%m%d)"
CURRENT_BUILD="$(/usr/bin/awk -F' = ' '/CURRENT_PROJECT_VERSION = [0-9]+;/{gsub(/;/,""); print $2; exit}' "$PROJECT_DIR/supacode.xcodeproj/project.pbxproj")"
if [[ "$CURRENT_BUILD" -ge "$BUILD" ]] 2>/dev/null; then
  BUILD="$((CURRENT_BUILD + 1))"
fi

log "version: $VERSION (build $BUILD), tag: $TAG"

# ── Bump version (skip if tag already exists) ────────────────────────────────

if git rev-parse "$TAG" >/dev/null 2>&1; then
  log "tag $TAG already exists, skipping bump"
else
  log "bumping version in project..."
  make bump-version VERSION="$VERSION" BUILD="$BUILD"
fi

# ── Update CHANGELOG ────────────────────────────────────────────────────────

CHANGELOG="CHANGELOG.md"
ENTRY_HEADER="## [$VERSION](https://github.com/$REPO/releases/tag/$TAG)"

if [[ -f "$CHANGELOG" ]] && grep -qF "$ENTRY_HEADER" "$CHANGELOG"; then
  log "CHANGELOG already contains entry for $VERSION, skipping"
else
  log "updating CHANGELOG.md..."
  {
    echo "# Changelog"
    echo ""
    echo "$ENTRY_HEADER"
    echo ""
    cat "$NOTES_FILE"
    echo ""
    if [[ -f "$CHANGELOG" ]]; then
      # Skip the "# Changelog" header and leading blank line
      tail -n +3 "$CHANGELOG"
    fi
  } > "${CHANGELOG}.tmp"
  mv "${CHANGELOG}.tmp" "$CHANGELOG"
  git add "$CHANGELOG"
  git commit -m "Update CHANGELOG for $VERSION"
  # Move tag to include the CHANGELOG commit
  git tag -f "$TAG" HEAD
fi

# ── Show release notes ───────────────────────────────────────────────────────

echo
echo "──── Release Notes ────"
cat "$NOTES_FILE"
echo "───────────────────────"
echo

# Confirm interactively if possible
if [[ -t 0 ]]; then
  read -rp "Proceed with release? [Y/n] " confirm
  case "${confirm:-Y}" in
    [Yy]*) ;;
    *) die "release aborted by user" ;;
  esac
fi

# ── Archive ──────────────────────────────────────────────────────────────────

log "archiving Release build..."
make archive APPLE_TEAM_ID="$TEAM_ID" DEVELOPER_ID_IDENTITY_SHA="$IDENTITY_SHA"

# ── Sentry: register release + upload dSYM ──────────────────────────────────
# Done right after archive so dSYM is ready before downstream steps. Failures
# only warn — release proceeds because dSYM can be re-uploaded later with
# `sentry-cli debug-files upload <dSYM>`.

SENTRY_RELEASE_NAME="prowl@$VERSION"
if [[ "$SENTRY_ENABLED" -eq 1 ]]; then
  log "creating Sentry release $SENTRY_RELEASE_NAME..."
  sentry-cli releases new "$SENTRY_RELEASE_NAME" \
    || log "WARNING: failed to create Sentry release (continuing)"

  DSYM_DIR="build/supacode.xcarchive/dSYMs"
  if [[ -d "$DSYM_DIR" ]]; then
    log "uploading dSYM from $DSYM_DIR to Sentry..."
    sentry-cli debug-files upload --include-sources --wait "$DSYM_DIR" \
      || log "WARNING: dSYM upload failed (release will continue; re-run sentry-cli debug-files upload later)"
  else
    log "WARNING: $DSYM_DIR not found, skipping dSYM upload"
  fi

  # Sparkle ships as a prebuilt binaryTarget (Sparkle.xcframework), so Xcode never emits a
  # dSYM for it into the archive — the archive-dSYM upload above therefore never covers
  # Sparkle. Upload the dSYMs bundled inside the xcframework directly so each new Sparkle
  # version is symbolicated automatically, instead of relying on a one-off manual bulk upload.
  SPARKLE_XCFRAMEWORK="$HOME/Library/Caches/supacode-spm-cache/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework"
  if [[ -d "$SPARKLE_XCFRAMEWORK" ]]; then
    log "uploading Sparkle xcframework dSYMs to Sentry..."
    sentry-cli debug-files upload --wait "$SPARKLE_XCFRAMEWORK" \
      || log "WARNING: Sparkle dSYM upload failed (release will continue)"
  else
    log "WARNING: $SPARKLE_XCFRAMEWORK not found, skipping Sparkle dSYM upload"
  fi

  log "associating commits with Sentry release..."
  sentry-cli releases set-commits "$SENTRY_RELEASE_NAME" --auto \
    || log "WARNING: failed to associate commits (continuing)"
fi

# ── Export ───────────────────────────────────────────────────────────────────

log "generating ExportOptions.plist..."
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>$SIGNING_IDENTITY</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
PLIST

log "exporting archive..."
make export-archive

# ── Locate exported app ─────────────────────────────────────────────────────

APP_PATH="$(find build/export -name "*.app" -maxdepth 3 -print -quit)"
[[ -d "$APP_PATH" ]] || die "exported app not found in build/export"
APP_NAME="$(basename "$APP_PATH")"
log "exported app: $APP_PATH"

# ── Re-sign Sparkle & Sentry frameworks ─────────────────────────────────────

log "re-signing embedded frameworks..."
SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"

if [[ -d "$SPARKLE" ]]; then
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SPARKLE/XPCServices/Installer.xpc"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp --preserve-metadata=entitlements -v "$SPARKLE/XPCServices/Downloader.xpc"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SPARKLE/Updater.app"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SPARKLE/Autoupdate"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SPARKLE/Sparkle"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$APP_PATH/Contents/Frameworks/Sparkle.framework"
fi

SENTRY_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sentry.framework"
if [[ -d "$SENTRY_FRAMEWORK" ]]; then
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SENTRY_FRAMEWORK/Versions/A/Sentry"
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$SENTRY_FRAMEWORK"
fi

# ── Re-sign bundled CLI ─────────────────────────────────────────────────────

PROWL_CLI="$APP_PATH/Contents/Resources/prowl-cli/prowl"
if [[ -f "$PROWL_CLI" ]]; then
  log "re-signing bundled prowl CLI with hardened runtime..."
  codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp -v "$PROWL_CLI"
fi

# ── Re-sign app ─────────────────────────────────────────────────────────────

log "re-signing app..."
codesign -f -s "$IDENTITY_SHA" -o runtime --timestamp --preserve-metadata=entitlements,requirements,flags -v "$APP_PATH"
codesign -vvv --deep --strict "$APP_PATH"
log "signature verified"

# ── DMG ──────────────────────────────────────────────────────────────────────

log "building DMG..."
DMG_PATH="build/Prowl.dmg"
mise exec -- create-dmg "$APP_PATH" build/ \
  --overwrite \
  --dmg-title="Prowl" \
  --no-code-sign

DMG_OUTPUT="$(find build -name "*.dmg" -maxdepth 1 -newer build/ExportOptions.plist | head -1)"
if [[ "$DMG_OUTPUT" != "$DMG_PATH" ]] && [[ -n "$DMG_OUTPUT" ]]; then
  mv "$DMG_OUTPUT" "$DMG_PATH"
fi
[[ -f "$DMG_PATH" ]] || die "DMG not found at $DMG_PATH"

log "compressing DMG with LZMA..."
bash "$SCRIPT_DIR/recompress-dmg.sh" "$DMG_PATH" "$DMG_PATH"
codesign -s "$IDENTITY_SHA" --timestamp "$DMG_PATH"
codesign --verify --strict "$DMG_PATH"

# ── Notarize ─────────────────────────────────────────────────────────────────

log "notarizing DMG..."
for attempt in 1 2 3; do
  if xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
    break
  fi
  if [[ $attempt -lt 3 ]]; then
    log "notarization attempt $attempt failed, retrying in 30s..."
    sleep 30
  else
    die "notarization failed after 3 attempts"
  fi
done

log "stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler staple "$APP_PATH"

# ── Package zip for Sparkle ──────────────────────────────────────────────────

ZIP_PATH="build/Prowl.app.zip"
log "packaging $ZIP_PATH for Sparkle..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# ── Appcast ──────────────────────────────────────────────────────────────────

log "generating appcast..."
STAGING="$(mktemp -d)"
ARCHIVE_BASE="$(basename "$ZIP_PATH" .zip)"
cp "$ZIP_PATH" "$STAGING/"
cp "$NOTES_FILE" "$STAGING/$ARCHIVE_BASE.md"

# Fetch existing appcast from the latest GitHub release for version history
curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" -o "$STAGING/appcast.xml" 2>/dev/null || true

"$PROJECT_DIR/bins/generate_appcast" \
  --ed-key-file "$SPARKLE_KEY_FILE" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --embed-release-notes \
  --maximum-versions 10 \
  "$STAGING"

cp "$STAGING/appcast.xml" build/appcast.xml
find "$STAGING" -name "*.delta" -exec cp {} build/ \; 2>/dev/null || true
rm -rf "$STAGING"
log "appcast generated at build/appcast.xml"

# ── Tag + push ───────────────────────────────────────────────────────────────

log "pushing tags..."
git push --follow-tags

# ── GitHub Release ───────────────────────────────────────────────────────────

log "creating GitHub Release..."
UPLOAD_FILES=("$DMG_PATH" "$ZIP_PATH" "build/appcast.xml")
DELTA_FILES=( $(find build -name "*.delta" -type f 2>/dev/null || true) )
UPLOAD_FILES+=("${DELTA_FILES[@]}")

# Delete existing release if present (idempotent re-run)
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  log "deleting existing release $TAG for re-creation..."
  gh release delete "$TAG" --repo "$REPO" --yes
fi

gh release create "$TAG" "${UPLOAD_FILES[@]}" \
  --repo "$REPO" \
  --title "Prowl $VERSION" \
  --notes-file "$NOTES_FILE"

RELEASE_URL="https://github.com/$REPO/releases/tag/$TAG"
log "release created: $RELEASE_URL"

# ── Finalize Sentry release ─────────────────────────────────────────────────
# Marks the release as deployed in Sentry's dashboard so issue tracking can
# associate "first seen in" with this version.

if [[ "$SENTRY_ENABLED" -eq 1 ]]; then
  log "finalizing Sentry release $SENTRY_RELEASE_NAME..."
  sentry-cli releases finalize "$SENTRY_RELEASE_NAME" \
    || log "WARNING: failed to finalize Sentry release (non-fatal)"
fi

# ── Trigger Prowl-Site rebuild ───────────────────────────────────────────────

log "triggering Prowl-Site rebuild..."
if [[ -n "${NETLIFY_BUILD_HOOK:-}" ]]; then
  curl -fsSL -X POST "$NETLIFY_BUILD_HOOK" 2>/dev/null \
    && log "Prowl-Site rebuild triggered" \
    || log "Prowl-Site rebuild trigger failed (non-critical)"
else
  log "NETLIFY_BUILD_HOOK not set, skipping Prowl-Site rebuild"
fi

echo
log "done! Release: $RELEASE_URL"
