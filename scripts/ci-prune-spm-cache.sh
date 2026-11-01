#!/usr/bin/env bash
# Remove package files that the macOS Debug build does not read from a SourcePackages folder.
set -euo pipefail

source_packages="$1"
sentry="$source_packages/artifacts/sentry-cocoa"

rm -rf "$source_packages/repositories"
rm -rf "$sentry/Sentry-Dynamic" "$sentry/Sentry-Dynamic-WithARM64e" \
  "$sentry/Sentry-WithoutUIKitOrAppKit" "$sentry/Sentry-WithoutUIKitOrAppKit-WithARM64e"
du -sh "$source_packages"
