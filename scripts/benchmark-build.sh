#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCENARIO="${1:-ci}"
SAMPLES="${2:-1}"
BENCHMARK_ROOT="${BUILD_BENCHMARK_ROOT:-$ROOT/.build-benchmark/build-time}"
SOURCE_PACKAGES="${SPM_CACHE_DIR:-$HOME/Library/Caches/prowl-spm-cache/SourcePackages}"
CAS_PATH="$BENCHMARK_ROOT/ci/CompilationCache.noindex"
DERIVED_DATA_PATH="$BENCHMARK_ROOT/ci/DerivedData"
RESULT_BUNDLE_PATH="$BENCHMARK_ROOT/ci/TestResults.xcresult"
RESULTS_PATH="$BENCHMARK_ROOT/results.jsonl"

usage() {
  cat <<'EOF'
Usage: scripts/benchmark-build.sh [scenario] [samples]

Scenarios:
  app-clean       Clean App build with compilation caching disabled.
  test-clean      Clean integrated App build/test with caching disabled.
  test-cas-cold   Clean integrated test with an empty compilation cache.
  test-cas-warm   Clean DerivedData, preserve and reuse the compilation cache.
  ci              Run test-cas-cold once, then test-cas-warm samples (default).
  all             Run app-clean, test-clean, then the ci sequence.

Environment:
  BUILD_BENCHMARK_ROOT  Stable artifact root (default: .build-benchmark/build-time).
  SPM_CACHE_DIR         SourcePackages path used by xcodebuild.
  BUILD_DIAGNOSTICS=1   Enable 500 ms type-checker diagnostics.
EOF
}

if [[ "$SCENARIO" == "-h" || "$SCENARIO" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! "$SAMPLES" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: samples must be a positive integer" >&2
  exit 2
fi

case "$SCENARIO" in
  app-clean | test-clean | test-cas-cold | test-cas-warm | ci | all) ;;
  *)
    echo "error: unknown scenario: $SCENARIO" >&2
    usage >&2
    exit 2
    ;;
esac

for command in git jq mise python3 xcodebuild; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error: required command not found: $command" >&2
    exit 127
  fi
done

if [[ ! -d "$SOURCE_PACKAGES" ]]; then
  echo "error: SourcePackages not found: $SOURCE_PACKAGES" >&2
  echo "Run make build-app once to resolve packages before benchmarking." >&2
  exit 1
fi

mkdir -p "$BENCHMARK_ROOT"
touch "$RESULTS_PATH"

GIT_SHA="$(git -C "$ROOT" rev-parse HEAD)"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
HARDWARE="$(sysctl -n machdep.cpu.brand_string)"
LOGICAL_CPUS="$(sysctl -n hw.logicalcpu)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_RESULTS="$BENCHMARK_ROOT/$RUN_ID.jsonl"

run_case() {
  local name="$1"
  local action="$2"
  local cache_mode="$3"
  local reset_cache="$4"
  local sample="$5"
  local case_dir="$BENCHMARK_ROOT/$RUN_ID/$name-$sample"
  local raw_log="$case_dir/xcodebuild.log"
  local toon_log="$case_dir/xcodebuild.toon"
  local status start end wall cas_bytes

  rm -rf "$DERIVED_DATA_PATH" "$RESULT_BUNDLE_PATH"
  if [[ "$reset_cache" == "yes" ]]; then
    rm -rf "$CAS_PATH"
  elif [[ "$cache_mode" == "warm" && ! -d "$CAS_PATH" ]]; then
    echo "error: warm CAS not found: $CAS_PATH" >&2
    echo "Run the test-cas-cold or ci scenario first." >&2
    return 1
  fi
  mkdir -p "$case_dir"

  local -a command=(
    xcodebuild
    -workspace "$ROOT/Prowl.xcworkspace"
    -scheme Prowl
    -configuration Debug
    -destination "platform=macOS,arch=$(uname -m)"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -skipMacroValidation
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"
    -showBuildTimingSummary
    SWIFT_COMPILATION_MODE=incremental
  )

  if [[ "$action" == "test" ]]; then
    command+=(
      -resultBundlePath "$RESULT_BUNDLE_PATH"
      CODE_SIGNING_ALLOWED=NO
      CODE_SIGNING_REQUIRED=NO
      CODE_SIGN_IDENTITY=
    )
  fi

  if [[ "$cache_mode" == "disabled" ]]; then
    command+=(COMPILATION_CACHE_ENABLE_CACHING=NO)
  else
    command+=(
      COMPILATION_CACHE_ENABLE_CACHING=YES
      COMPILATION_CACHE_CAS_PATH="$CAS_PATH"
    )
  fi

  if [[ "${BUILD_DIAGNOSTICS:-0}" == "1" ]]; then
    command+=(
      'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -warn-long-function-bodies=500 -Xfrontend -warn-long-expression-type-checking=500'
    )
  fi

  command+=("$action")

  echo
  echo "==> $name sample $sample"
  echo "DerivedData: $DERIVED_DATA_PATH"
  echo "Compilation cache: $cache_mode"
  printf 'Command:'
  printf ' %q' "${command[@]}"
  echo

  start="$(python3 -c 'import time; print(time.time())')"
  set +e
  (
    cd "$ROOT"
    "${command[@]}" 2>&1 | tee "$raw_log" | mise exec -- xcsift -w --build-info --format toon | tee "$toon_log"
  )
  status=${PIPESTATUS[0]}
  set -e
  end="$(python3 -c 'import time; print(time.time())')"
  wall="$(python3 - "$start" "$end" <<'PY'
import sys
print(f"{float(sys.argv[2]) - float(sys.argv[1]):.3f}")
PY
)"

  cas_bytes=0
  if [[ -d "$CAS_PATH" ]]; then
    cas_bytes="$(( $(du -sk "$CAS_PATH" | awk '{print $1}') * 1024 ))"
  fi

  jq -cn \
    --arg runID "$RUN_ID" \
    --arg scenario "$name" \
    --argjson sample "$sample" \
    --arg gitSHA "$GIT_SHA" \
    --arg xcode "$XCODE_VERSION" \
    --arg hardware "$HARDWARE" \
    --argjson logicalCPUs "$LOGICAL_CPUS" \
    --argjson wallSeconds "$wall" \
    --argjson status "$status" \
    --argjson casBytes "$cas_bytes" \
    --arg rawLog "${raw_log#$ROOT/}" \
    --arg resultBundle "${RESULT_BUNDLE_PATH#$ROOT/}" \
    '{
      run_id: $runID,
      scenario: $scenario,
      sample: $sample,
      git_sha: $gitSHA,
      xcode: $xcode,
      hardware: $hardware,
      logical_cpus: $logicalCPUs,
      wall_seconds: $wallSeconds,
      status: $status,
      compilation_cache_bytes: $casBytes,
      raw_log: $rawLog,
      result_bundle: $resultBundle
    }' | tee -a "$RUN_RESULTS" >> "$RESULTS_PATH"

  echo "Result: $name sample $sample = ${wall}s (status $status)"
  if [[ "$status" -ne 0 ]]; then
    return "$status"
  fi
}

run_samples() {
  local name="$1"
  local action="$2"
  local cache_mode="$3"
  local reset_first="$4"
  local sample

  for ((sample = 1; sample <= SAMPLES; sample++)); do
    local reset="no"
    if [[ "$reset_first" == "each" || ( "$reset_first" == "yes" && "$sample" -eq 1 ) ]]; then
      reset="yes"
    fi
    run_case "$name" "$action" "$cache_mode" "$reset" "$sample"
  done
}

case "$SCENARIO" in
  app-clean)
    run_samples app-clean build disabled no
    ;;
  test-clean)
    run_samples test-clean test disabled no
    ;;
  test-cas-cold)
    run_samples test-cas-cold test cold each
    ;;
  test-cas-warm)
    run_samples test-cas-warm test warm no
    ;;
  ci)
    run_case test-cas-cold test cold yes 1
    run_samples test-cas-warm test warm no
    ;;
  all)
    run_samples app-clean build disabled no
    run_samples test-clean test disabled no
    run_case test-cas-cold test cold yes 1
    run_samples test-cas-warm test warm no
    ;;
esac

python3 - "$RUN_RESULTS" <<'PY'
import json
import statistics
import sys
from collections import defaultdict

values = defaultdict(list)
with open(sys.argv[1]) as stream:
    for line in stream:
        record = json.loads(line)
        values[record["scenario"]].append(record["wall_seconds"])

print("\nSummary:")
for scenario, samples in values.items():
    print(
        f"  {scenario}: n={len(samples)} "
        f"median={statistics.median(samples):.3f}s "
        f"min={min(samples):.3f}s max={max(samples):.3f}s"
    )
PY

echo "Results: $RUN_RESULTS"
echo "History: $RESULTS_PATH"
