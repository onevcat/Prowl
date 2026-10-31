#!/usr/bin/env bash
# Confirms that an app bundle contains the Ghostty that the submodule pins. The
# submodule pin alone does not prove this: the build links whatever GhosttyKit
# is installed locally.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <app-bundle> <pinned-ghostty-sha>" >&2
  exit 2
fi

app="$1"
pinned_sha="$2"
entry="$app/Contents/MacOS/ghostty"

if [[ ! -x "$entry" ]]; then
  echo "error: Ghostty CLI entry not found: $entry" >&2
  exit 1
fi

output="$("$entry" +version 2>&1)"
version="${output%%$'\n'*}"

if [[ "$version" != *"+${pinned_sha:0:7}"* ]]; then
  echo "error: the bundle reports \"$version\", but the submodule pins ${pinned_sha:0:9}." >&2
  echo "       Run make ensure-ghostty and build again." >&2
  exit 1
fi

echo "Bundled Ghostty matches the pin: $version"
