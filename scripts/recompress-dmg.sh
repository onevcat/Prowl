#!/usr/bin/env bash

# Conversion removes the image signature. Sign the output before notarization.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: recompress-dmg.sh SOURCE.dmg OUTPUT.dmg" >&2
  exit 2
fi

source_image="$1"
output_image="$2"
temporary_dir="$(mktemp -d "$(dirname "$output_image")/.dmg-compression.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

# ULMO uses LZMA and is supported by every macOS version that Prowl supports.
# Keep the previous output intact if conversion fails or is interrupted.
hdiutil convert "$source_image" -format ULMO -o "$temporary_dir/Prowl.dmg"
mv -f "$temporary_dir/Prowl.dmg" "$output_image"
