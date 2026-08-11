#!/usr/bin/env bash
# Print the code-signing identity for local Debug products, or nothing when there
# is none to use. Callers treat empty output as "leave it ad-hoc".
#
# Precedence: an explicit PROWL_CODESIGN_IDENTITY wins, with "-" opting out;
# otherwise auto-select an identity that carries a Team ID. Only stdout carries
# the identity, so callers can capture it with $(...) while the notes go to
# stderr.
set -euo pipefail

explicit="${PROWL_CODESIGN_IDENTITY:-}"
if [ "$explicit" = "-" ]; then
  exit 0
fi
if [ -n "$explicit" ]; then
  if ! security find-identity -v -p codesigning | grep -qF "\"$explicit\""; then
    echo "error: code-signing identity '$explicit' not found." >&2
    echo "Name an available identity in PROWL_CODESIGN_IDENTITY, or set it to '-' to opt out." >&2
    exit 1
  fi
  printf '%s\n' "$explicit"
  exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
  exit 0
fi

# `|| true`: grep exits 1 when no identity matches, which under `set -e` would
# abort before the empty-output path below.
identity="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Apple Development|Apple Distribution|Developer ID Application): [^"]*"' \
  | sed 's/^"//; s/"$//' | head -n1 || true)"

if [ -z "$identity" ]; then
  echo "note: no Team-ID signing identity found; Debug products stay ad-hoc." >&2
  echo "      macOS re-asks for Documents, Desktop, Downloads and Music on every rebuild." >&2
  echo "      Add an Apple Development identity, or point PROWL_CODESIGN_IDENTITY at a" >&2
  echo "      self-signed one, for prompt-free rebuilds." >&2
  exit 0
fi

printf '%s\n' "$identity"
