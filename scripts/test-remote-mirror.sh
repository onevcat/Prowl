#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# Run the real app test target so shared runtime dependencies cannot drift out of a copied harness.
exec xcodebuild test -project supacode.xcodeproj -scheme supacode \
  -destination 'platform=macOS' -skipMacroValidation \
  -only-testing:supacodeTests/MirrorProtocolTests \
  -only-testing:supacodeTests/MirrorHostTests \
  -only-testing:supacodeTests/MirrorConnectionTests \
  -only-testing:supacodeTests/MirrorTerminalIntegrationTests \
  "$@"
