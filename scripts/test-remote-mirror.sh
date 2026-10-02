#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# Run the real app test target so shared runtime dependencies cannot drift out of a copied harness.
make ensure-project
exec xcodebuild test -workspace Prowl.xcworkspace -scheme Prowl \
  -destination 'platform=macOS' -skipMacroValidation \
  -only-testing:ProwlTests/MirrorProtocolTests \
  -only-testing:ProwlTests/MirrorHostTests \
  -only-testing:ProwlTests/MirrorConnectionTests \
  -only-testing:ProwlTests/MirrorTerminalIntegrationTests \
  "$@"
