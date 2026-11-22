#!/usr/bin/env bash
# Runs every Mirror push test across the Host, the iOS app and the gateway (docs-ai 095
# `test-scenarios.md`). The three parts check one shared contract,
# Mirror/Fixtures/push/contract.json. Run it after changing any of them.
#
#   scripts/test-mirror-push.sh            # Host + iOS (+ gateway when its checkout exists)
#   GATEWAY_DIR=/path/to/prowl-push-gateway scripts/test-mirror-push.sh
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
gateway_dir="${GATEWAY_DIR:-$project_dir/../prowl-push-gateway}"
status=0

echo "== Host (macOS)"
make ensure-project
xcodebuild test -workspace Prowl.xcworkspace -scheme Prowl -destination 'platform=macOS' -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -only-testing:ProwlTests/MirrorPushContractTests \
  -only-testing:ProwlTests/MirrorPushPlannerTests \
  -only-testing:ProwlTests/PaneAgentStateCompletedTurnTests \
  -only-testing:ProwlTests/MirrorPushRegistrationTests \
  -only-testing:ProwlTests/MirrorHostTests \
  | mise exec -- xcsift -w --format toon || status=1

echo "== iOS app (simulator)"
make ensure-mirror-ios-project
destination="$(python3 scripts/select_ios_simulator.py 'iPad Pro 11-inch \(M[0-9]+\)')"
xcodebuild test -project Mirror/iOS/ProwlMirror-iOS.xcodeproj -scheme ProwlMirror-iOS -destination "$destination" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:ProwlMirror-iOSTests/MirrorPushContractTests \
  -only-testing:ProwlMirror-iOSTests/MirrorPushCryptoTests \
  -only-testing:ProwlMirror-iOSTests/MirrorPushKeyStoreTests \
  -only-testing:ProwlMirror-iOSTests/MirrorPushNotificationTests \
  -only-testing:ProwlMirror-iOSTests/MirrorPushGatewayClientTests \
  -only-testing:ProwlMirror-iOSTests/MirrorAPNsEnvironmentTests \
  -only-testing:ProwlMirror-iOSTests/MirrorPushCoordinatorTests \
  -only-testing:ProwlMirror-iOSTests/MirrorPushTokenLedgerTests \
  -only-testing:ProwlMirror-iOSTests/MirrorPushStatusTextTests \
  -only-testing:ProwlMirror-iOSTests/MirrorNotificationRouterTests \
  -only-testing:ProwlMirror-iOSTests/MirrorHostSessionTests \
  | mise exec -- xcsift -w --format toon || status=1

echo "== Gateway"
if [[ -f "$gateway_dir/package.json" ]]; then
  if ! cmp -s Mirror/Fixtures/push/contract.json "$gateway_dir/test/fixtures/prowl-push-contract.json"; then
    echo "The gateway's contract copy differs from Mirror/Fixtures/push/contract.json; copy it over." >&2
    status=1
  fi
  (cd "$gateway_dir" && npm test && npm run -s typecheck) || status=1
else
  echo "SKIPPED: no gateway checkout at $gateway_dir (set GATEWAY_DIR)"
fi

exit $status
