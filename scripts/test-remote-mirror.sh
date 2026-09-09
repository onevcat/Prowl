#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness_dir="$(mktemp -d "${TMPDIR:-/tmp}/prowl-mirror-tests.XXXXXX")"
trap 'rm -rf "$harness_dir"' EXIT
mkdir -p "$harness_dir/Sources/MirrorHarness" "$harness_dir/Tests/MirrorHarnessTests"
cat > "$harness_dir/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MirrorHarness", platforms: [.macOS("26.0")], targets: [
  .target(name: "MirrorHarness"), .testTarget(name: "MirrorHarnessTests", dependencies: ["MirrorHarness"])
])
PACKAGE
for name in MirrorProtocol MirrorConnection MirrorPaneSource MirrorHost; do
  cp "$project_dir/supacode/Features/RemoteMirror/$name.swift" "$harness_dir/Sources/MirrorHarness/"
done
for name in MirrorProtocolTests MirrorHostTests; do
  sed 's/@testable import supacode/@testable import MirrorHarness/' \
    "$project_dir/supacodeTests/RemoteMirror/$name.swift" > "$harness_dir/Tests/MirrorHarnessTests/$name.swift"
done
xcrun swift test --package-path "$harness_dir"
