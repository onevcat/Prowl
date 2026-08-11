# Sensible defaults
.ONESHELL:
SHELL := bash
.SHELLFLAGS := -e -u -c -o pipefail
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

# Derived values (DO NOT TOUCH).
CURRENT_MAKEFILE_PATH := $(abspath $(lastword $(MAKEFILE_LIST)))
CURRENT_MAKEFILE_DIR := $(patsubst %/,%,$(dir $(CURRENT_MAKEFILE_PATH)))
GHOSTTY_XCFRAMEWORK_PATH := $(CURRENT_MAKEFILE_DIR)/Frameworks/GhosttyKit.xcframework
GHOSTTY_RESOURCE_PATH := $(CURRENT_MAKEFILE_DIR)/Resources/ghostty
GHOSTTY_TERMINFO_PATH := $(CURRENT_MAKEFILE_DIR)/Resources/terminfo
GHOSTTY_BUILD_OUTPUTS := $(GHOSTTY_XCFRAMEWORK_PATH) $(GHOSTTY_RESOURCE_PATH) $(GHOSTTY_TERMINFO_PATH)
GHOSTTY_BUILD_STAMP := $(CURRENT_MAKEFILE_DIR)/.ghostty_build_stamp
GHOSTTY_HASH_FILE := $(CURRENT_MAKEFILE_DIR)/.ghostty_hash
SPM_CACHE_DIR := $(HOME)/Library/Caches/supacode-spm-cache/SourcePackages
CLI_DEBUG_RESOURCE_PATH := $(CURRENT_MAKEFILE_DIR)/Resources/prowl-cli/prowl
CLI_SOURCE_DIRS := $(CURRENT_MAKEFILE_DIR)/ProwlCLI $(CURRENT_MAKEFILE_DIR)/supacode/CLIService/Shared
CLI_SOURCE_INPUTS := \
	$(CURRENT_MAKEFILE_PATH) \
	$(CURRENT_MAKEFILE_DIR)/Package.swift \
	$(CURRENT_MAKEFILE_DIR)/Package.resolved \
	$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj \
	$(shell find $(CLI_SOURCE_DIRS) -type f 2>/dev/null)
VERSION ?=
BUILD ?=
XCODEBUILD_FLAGS ?=
BUILD_BENCHMARK_SCENARIO ?= ci
BUILD_BENCHMARK_SAMPLES ?= 1
CLI_INTEGRATION_TEST_FILTER ?= ProwlCLIIntegrationTests
FORMAT_BASE_REF ?= origin/main
BUILD_SETTINGS_CACHE := $(CURRENT_MAKEFILE_DIR)/.build_settings_cache.json
PBXPROJ_PATH := $(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj

# Code-signing identity for the Debug bundle. Empty auto-selects one that carries
# a Team ID; "-" opts out and keeps xcodebuild's ad-hoc signature. See sign-debug-app.
PROWL_CODESIGN_IDENTITY ?=

# Release-only analytics/crash credentials. Included from Config/Secrets.env if present,
# or overridable from the environment (e.g. CI). Debug builds skip SDK init regardless.
-include Config/Secrets.env
PROWL_SENTRY_DSN ?=
PROWL_POSTHOG_API_KEY ?=
PROWL_POSTHOG_HOST ?=

.DEFAULT_GOAL := help
.PHONY: build-ghostty-xcframework ensure-ghostty sync-ghostty _record-ghostty-hash build-app build-cli build-cli-release embed-cli-debug embed-cli embed-docs run-app sign-debug-app install-dev-build install-release archive export-archive format format-changed format-lint lint check test test-app test-scripts test-cli-smoke test-cli-integration benchmark-build bump-version log-stream

help:  # Display this help.
	@-+echo "Run make with one of the following targets:"
	@-+echo
	@-+grep -Eh "^[a-z-]+:.*#" $(CURRENT_MAKEFILE_PATH) | sed -E 's/^(.*:)(.*#+)(.*)/  \1 @@@ \3 /' | column -t -s "@@@"

build-ghostty-xcframework: $(GHOSTTY_BUILD_STAMP) # Build ghostty framework
	@$(MAKE) _record-ghostty-hash

# Internal: actually rebuild ghostty.
$(GHOSTTY_BUILD_STAMP):
	git submodule update --init --recursive ThirdParty/ghostty
	@cd $(CURRENT_MAKEFILE_DIR)/ThirdParty/ghostty && mise exec -- zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Dsentry=false
	rsync -a ThirdParty/ghostty/macos/GhosttyKit.xcframework Frameworks
	@src="$(CURRENT_MAKEFILE_DIR)/ThirdParty/ghostty/zig-out/share/ghostty"; \
	dst="$(GHOSTTY_RESOURCE_PATH)"; \
	terminfo_src="$(CURRENT_MAKEFILE_DIR)/ThirdParty/ghostty/zig-out/share/terminfo"; \
	terminfo_dst="$(GHOSTTY_TERMINFO_PATH)"; \
	mkdir -p "$$dst"; \
	rsync -a --delete "$$src/" "$$dst/"; \
	mkdir -p "$$terminfo_dst"; \
	rsync -a --delete "$$terminfo_src/" "$$terminfo_dst/"
	touch "$(GHOSTTY_BUILD_STAMP)"

# Public entry point: downloads pinned prebuilt artifacts when available, then
# falls back to a local Ghostty source build.
ensure-ghostty: # Ensure GhosttyKit is up-to-date (fast path when unchanged)
	@set +e; \
	"$(CURRENT_MAKEFILE_DIR)/scripts/ensure-ghosttykit-artifacts.sh"; \
	status="$$?"; \
	set -e; \
	if [ "$$status" -eq 0 ]; then \
		exit 0; \
	fi; \
	if [ "$$status" -ne 2 ]; then \
		exit "$$status"; \
	fi; \
	current_sha="$$(git -C "$(CURRENT_MAKEFILE_DIR)" rev-parse HEAD:ThirdParty/ghostty)"; \
	last_sha=""; \
	if [ -f "$(GHOSTTY_HASH_FILE)" ]; then \
		last_sha="$$(cat "$(GHOSTTY_HASH_FILE)")"; \
	fi; \
	echo "Building GhosttyKit locally for $$current_sha"; \
	$(MAKE) -B build-ghostty-xcframework; \
	if [ "$$current_sha" != "$$last_sha" ]; then \
		rm -rf ~/Library/Developer/Xcode/DerivedData/supacode-*; \
		echo "Cleared Xcode DerivedData for ghostty header/module changes"; \
	fi

# Internal: record the current submodule SHA after a successful build.
_record-ghostty-hash:
	@git -C "$(CURRENT_MAKEFILE_DIR)" rev-parse HEAD:ThirdParty/ghostty > "$(GHOSTTY_HASH_FILE)"

# Force a clean rebuild of GhosttyKit (ignores cached SHA, useful after submodule updates).
sync-ghostty: # Force sync GhosttyKit to current submodule HEAD (always rebuilds)
	@echo "Forcing GhosttyKit rebuild..."
	$(MAKE) -B build-ghostty-xcframework
	rm -rf ~/Library/Developer/Xcode/DerivedData/supacode-*
	@echo "Done. Xcode module cache cleared for fresh compilation."

embed-docs: # Stage docs/ into Resources for bundling into the app (.app/Contents/Resources/docs)
	@set -euo pipefail; \
	src="$(CURRENT_MAKEFILE_DIR)/docs"; \
	dst="$(CURRENT_MAKEFILE_DIR)/Resources/docs"; \
	mkdir -p "$$dst"; \
	rsync -a --delete --exclude '.sync-meta.json' "$$src/" "$$dst/"; \
	echo "embedded docs at $$dst"

build-app: ensure-ghostty embed-cli-debug embed-docs # Build the macOS app (Debug)
	bash -o pipefail -c 'xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug build -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) SWIFT_COMPILATION_MODE=incremental 2>&1 | mise exec -- xcsift -w --format toon'
	@$(MAKE) --no-print-directory sign-debug-app

# Resolve BUILT_PRODUCTS_DIR and FULL_PRODUCT_NAME for the Debug configuration into
# $$build_dir and $$product, reading the cached build settings when they are newer
# than the project file. Leaves $$settings in scope for callers that need more fields.
define resolve_debug_product
	cache="$(BUILD_SETTINGS_CACHE)"; \
	pbxproj="$(PBXPROJ_PATH)"; \
	if [ -f "$$cache" ] && [ "$$cache" -nt "$$pbxproj" ]; then \
		settings="$$(cat "$$cache")"; \
	else \
		settings="$$(xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug -showBuildSettings -json 2>/dev/null)"; \
		printf '%s' "$$settings" > "$$cache"; \
	fi; \
	build_dir="$$(echo "$$settings" | jq -er '.[0].buildSettings.BUILT_PRODUCTS_DIR')"; \
	product="$$(echo "$$settings" | jq -er '.[0].buildSettings.FULL_PRODUCT_NAME')";
endef

# Sign the Debug bundle with a stable identity. TCC stores the code requirement it
# granted against, and an ad-hoc signature's requirement is pinned to the cdhash,
# which every build changes: the grant stops matching and macOS re-asks for
# Documents, Desktop, Downloads and Music. Those prompts name Prowl because a
# terminal child's file access is attributed to the app responsible for it, so the
# agents running in panes trip them. A named identity yields a cdhash-free
# requirement, and the answers survive rebuilds.
#
# Precedence: an explicit PROWL_CODESIGN_IDENTITY wins, with "-" opting out;
# otherwise auto-select an identity carrying a Team ID. When none exists the
# bundle keeps its ad-hoc signature and the reason is announced rather than
# silently accepted, because the prompts would otherwise look like a Prowl bug.
sign-debug-app: # Sign the built Debug app so TCC grants survive rebuilds
	@set -euo pipefail; \
	if [ "$$(uname -s)" != "Darwin" ]; then \
		exit 0; \
	fi; \
	identity="$(PROWL_CODESIGN_IDENTITY)"; \
	if [ "$$identity" = "-" ]; then \
		echo "code-signing opted out (PROWL_CODESIGN_IDENTITY=-): keeping the ad-hoc signature." >&2; \
		exit 0; \
	fi; \
	if [ -z "$$identity" ]; then \
		identity="$$(security find-identity -v -p codesigning 2>/dev/null \
			| grep -oE '"(Apple Development|Apple Distribution|Developer ID Application): [^"]*"' \
			| sed 's/^"//; s/"$$//' | head -n1 || true)"; \
	fi; \
	if [ -z "$$identity" ]; then \
		echo "note: no Team-ID signing identity found; leaving the ad-hoc signature." >&2; \
		echo "      macOS re-asks for Documents, Desktop, Downloads and Music on every rebuild." >&2; \
		echo "      Add an Apple Development identity, or point PROWL_CODESIGN_IDENTITY at a" >&2; \
		echo "      self-signed one, for prompt-free rebuilds." >&2; \
		exit 0; \
	fi; \
	if ! security find-identity -v -p codesigning | grep -qF "\"$$identity\""; then \
		echo "error: code-signing identity '$$identity' not found." >&2; \
		echo "Name an available identity in PROWL_CODESIGN_IDENTITY, or set it to '-' to opt out." >&2; \
		exit 1; \
	fi; \
	$(resolve_debug_product) \
	if [ -z "$$build_dir" ] || [ -z "$$product" ] || [ "$$build_dir" = "null" ] || [ "$$product" = "null" ]; then \
		echo "error: failed to resolve app path from build settings"; \
		exit 1; \
	fi; \
	app="$$build_dir/$$product"; \
	if [ ! -d "$$app/Contents" ]; then \
		echo "error: not an app bundle: $$app"; \
		exit 1; \
	fi; \
	codesign --force --sign "$$identity" --preserve-metadata=entitlements "$$app"; \
	codesign --verify --verbose=4 "$$app" >/dev/null 2>&1 || { \
		echo "error: '$$app' failed code-signature verification." >&2; \
		codesign --verify --verbose=4 "$$app" >&2 || true; \
		exit 1; \
	}; \
	dr="$$(codesign --display --requirements - "$$app" 2>&1)"; \
	case "$$dr" in \
		*cdhash*) \
			echo "error: designated requirement is cdhash-pinned; TCC grants will not survive a rebuild." >&2; \
			printf '%s\n' "$$dr" >&2; \
			exit 1; \
			;; \
	esac; \
	echo "signed $$app with '$$identity'"

sync-cli-version: # Sync app MARKETING_VERSION into ProwlCLIShared/ProwlVersion.swift
	@version="$$(/usr/bin/awk -F' = ' '/MARKETING_VERSION = [0-9.]*;/{gsub(/;/,"",$$2);print $$2; exit}' \
		"$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj")"; \
	dst="$(CURRENT_MAKEFILE_DIR)/supacode/CLIService/Shared/ProwlVersion.swift"; \
	tmp="$$(mktemp)"; \
	trap 'rm -f "$$tmp"' EXIT; \
	printf '// Auto-generated by Makefile (sync-cli-version). Do not edit.\n\npublic enum ProwlVersion {\n  public static let current = "%s"\n}\n' "$$version" > "$$tmp"; \
	if [ ! -f "$$dst" ] || ! cmp -s "$$tmp" "$$dst"; then \
		mv "$$tmp" "$$dst"; \
		echo "synced CLI version $$version"; \
	fi

build-cli: sync-cli-version # Build Swift CLI binary (SPM)
	swift build --product prowl

build-cli-release: sync-cli-version # Build universal CLI binary in release mode
	swift build -c release --arch arm64 --arch x86_64 --product prowl

embed-cli-debug: $(CLI_DEBUG_RESOURCE_PATH) # Build debug CLI and copy into Resources for dev builds

$(CLI_DEBUG_RESOURCE_PATH): $(CLI_SOURCE_INPUTS)
	$(MAKE) build-cli
	@set -euo pipefail; \
	bin="$$(swift build --show-bin-path)/prowl"; \
	dst="$(CURRENT_MAKEFILE_DIR)/Resources/prowl-cli"; \
	mkdir -p "$$dst"; \
	if [ ! -f "$$dst/prowl" ] || ! cmp -s "$$bin" "$$dst/prowl"; then \
		cp "$$bin" "$$dst/prowl"; \
	else \
		touch "$$dst/prowl"; \
	fi; \
	chmod +x "$$dst/prowl"; \
	echo "embedded CLI binary at $$dst/prowl"

embed-cli: build-cli-release # Build release CLI and copy into Resources for distribution
	@set -euo pipefail; \
	bin="$$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/prowl"; \
	dst="$(CURRENT_MAKEFILE_DIR)/Resources/prowl-cli"; \
	mkdir -p "$$dst"; \
	cp "$$bin" "$$dst/prowl"; \
	chmod +x "$$dst/prowl"; \
	echo "embedded CLI binary at $$dst/prowl"

run-app: build-app # Build then launch (Debug) with log streaming
	@set -euo pipefail; \
	$(resolve_debug_product) \
	exec_name="$$(echo "$$settings" | jq -r '.[0].buildSettings.EXECUTABLE_NAME')"; \
	if [ -z "$$build_dir" ] || [ -z "$$product" ] || [ "$$build_dir" = "null" ] || [ "$$product" = "null" ] || [ -z "$$exec_name" ] || [ "$$exec_name" = "null" ]; then \
		echo "error: failed to resolve app path from build settings"; \
		exit 1; \
	fi; \
	app_path="$$build_dir/$$product/Contents/MacOS/$$exec_name"; \
	"$$app_path"

install-dev-build: build-app # Build Debug and install to /Applications
	@set -euo pipefail; \
	$(resolve_debug_product) \
	if [ -z "$$build_dir" ] || [ -z "$$product" ] || [ "$$build_dir" = "null" ] || [ "$$product" = "null" ]; then \
		echo "error: failed to resolve app path from build settings"; \
		exit 1; \
	fi; \
	if [ "$$product" != "$$(basename "$$product")" ]; then \
		echo "error: invalid product name (contains path separators): $$product"; \
		exit 1; \
	fi; \
	if [[ "$$product" != *.app ]]; then \
		echo "error: unexpected product name: $$product"; \
		exit 1; \
	fi; \
	src="$$build_dir/$$product"; \
	dst="/Applications/$$product"; \
	dst_parent="$$(cd "$$(dirname "$$dst")" && pwd -P)"; \
	if [ "$$dst_parent" != "/Applications" ]; then \
		echo "error: refusing to install outside /Applications: $$dst"; \
		exit 1; \
	fi; \
	if [ "$$src" = "/" ] || [ "$$dst" = "/Applications" ] || [ "$$dst" = "/Applications/" ]; then \
		echo "error: unsafe install path (src=$$src, dst=$$dst)"; \
		exit 1; \
	fi; \
	case "$$dst" in \
		/Applications/*.app) ;; \
		*) \
			echo "error: refusing to install outside /Applications/*.app: $$dst"; \
			exit 1; \
			;; \
	esac; \
	if [ ! -d "$$src" ]; then \
		echo "app not found: $$src"; \
		exit 1; \
	fi; \
	if [ ! -d "$$src/Contents" ]; then \
		echo "error: source is not an app bundle: $$src"; \
		exit 1; \
	fi; \
	echo "copying $$src -> $$dst"; \
	if [ -e "$$dst" ]; then \
		if ! command -v trash >/dev/null 2>&1; then \
			echo "error: trash command not found; refusing to remove $$dst"; \
			exit 1; \
		fi; \
		echo "moving existing app to Trash: $$dst"; \
		trash "$$dst"; \
	fi; \
	ditto "$$src" "$$dst"; \
	echo "installed $$dst"

install-release: build-ghostty-xcframework # Build Release, sign locally, install to /Applications
	@set -euo pipefail; \
	SIGNING_IDENTITY="$$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $$2; exit}')"; \
	if [ -z "$$SIGNING_IDENTITY" ]; then \
		echo "error: no Developer ID Application identity found"; \
		exit 1; \
	fi; \
	IDENTITY_SHA="$$(security find-identity -v -p codesigning 2>/dev/null | grep "$$SIGNING_IDENTITY" | head -1 | awk '{print $$2}')"; \
	TEAM_ID="$$(echo "$$SIGNING_IDENTITY" | grep -oE '\([A-Z0-9]{10}\)$$' | tr -d '()')"; \
	echo "identity: $$SIGNING_IDENTITY"; \
	echo "team: $$TEAM_ID"; \
	APPLE_TEAM_ID="$$TEAM_ID" DEVELOPER_ID_IDENTITY_SHA="$$IDENTITY_SHA" $(MAKE) archive; \
	mkdir -p build; \
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'  <key>method</key>' \
		'  <string>developer-id</string>' \
		'  <key>signingStyle</key>' \
		'  <string>manual</string>' \
		'  <key>signingCertificate</key>' \
		"  <string>$$SIGNING_IDENTITY</string>" \
		'  <key>teamID</key>' \
		"  <string>$$TEAM_ID</string>" \
		'</dict>' \
		'</plist>' > build/ExportOptions.plist; \
	$(MAKE) export-archive; \
	APP_PATH="$$(find build/export -name '*.app' -maxdepth 3 -print -quit)"; \
	if [ ! -d "$$APP_PATH" ]; then \
		echo "error: exported app not found"; \
		exit 1; \
	fi; \
	SPARKLE="$$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"; \
	if [ -d "$$SPARKLE" ]; then \
		codesign -f -s "$$IDENTITY_SHA" -o runtime --timestamp -v "$$SPARKLE/XPCServices/Installer.xpc"; \
		codesign -f -s "$$IDENTITY_SHA" -o runtime --timestamp --preserve-metadata=entitlements -v "$$SPARKLE/XPCServices/Downloader.xpc"; \
		codesign -f -s "$$IDENTITY_SHA" -o runtime --timestamp -v "$$SPARKLE/Updater.app"; \
		codesign -f -s "$$IDENTITY_SHA" -o runtime --timestamp -v "$$SPARKLE/Autoupdate"; \
		codesign -f -s "$$IDENTITY_SHA" -o runtime --timestamp -v "$$SPARKLE/Sparkle"; \
		codesign -f -s "$$IDENTITY_SHA" -o runtime --timestamp -v "$$APP_PATH/Contents/Frameworks/Sparkle.framework"; \
	fi; \
	SENTRY="$$APP_PATH/Contents/Frameworks/Sentry.framework"; \
	if [ -d "$$SENTRY" ]; then \
		codesign -f -s "$$IDENTITY_SHA" -o runtime --timestamp -v "$$SENTRY/Versions/A/Sentry"; \
		codesign -f -s "$$IDENTITY_SHA" -o runtime --timestamp -v "$$SENTRY"; \
	fi; \
	codesign -f -s "$$IDENTITY_SHA" -o runtime --timestamp --preserve-metadata=entitlements,requirements,flags -v "$$APP_PATH"; \
	codesign -vvv --deep --strict "$$APP_PATH"; \
	PRODUCT="$$(basename "$$APP_PATH")"; \
	if [ -z "$$PRODUCT" ] || [ "$$PRODUCT" = "." ] || [[ "$$PRODUCT" != *.app ]]; then \
		echo "error: unexpected release product name: $$PRODUCT"; \
		exit 1; \
	fi; \
	DST="/Applications/$$PRODUCT"; \
	if [ "$$DST" = "/Applications" ] || [ "$$DST" = "/Applications/" ]; then \
		echo "error: unsafe install destination: $$DST"; \
		exit 1; \
	fi; \
	case "$$DST" in \
		/Applications/*.app) ;; \
		*) \
			echo "error: refusing to install outside /Applications/*.app: $$DST"; \
			exit 1; \
			;; \
	esac; \
	echo "copying $$APP_PATH -> $$DST"; \
	if [ -e "$$DST" ]; then \
		if ! command -v trash >/dev/null 2>&1; then \
			echo "error: trash command not found; refusing to remove $$DST"; \
			exit 1; \
		fi; \
		echo "moving existing app to Trash: $$DST"; \
		trash "$$DST"; \
	fi; \
	ditto "$$APP_PATH" "$$DST"; \
	echo "installed $$DST (Release build, locally signed)"

archive: build-ghostty-xcframework embed-cli embed-docs # Archive Release build for distribution
	bash -o pipefail -c 'xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Release -archivePath build/supacode.xcarchive archive CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$$APPLE_TEAM_ID" CODE_SIGN_IDENTITY="$$DEVELOPER_ID_IDENTITY_SHA" OTHER_CODE_SIGN_FLAGS="--timestamp" PROWL_SENTRY_DSN="$(PROWL_SENTRY_DSN)" PROWL_POSTHOG_API_KEY="$(PROWL_POSTHOG_API_KEY)" PROWL_POSTHOG_HOST="$(PROWL_POSTHOG_HOST)" -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) $(XCODEBUILD_FLAGS) 2>&1 | mise exec -- xcsift -qw --format toon'

export-archive: # Export xarchive
	bash -o pipefail -c 'xcodebuild -exportArchive -archivePath build/supacode.xcarchive -exportPath build/export -exportOptionsPlist build/ExportOptions.plist 2>&1 | mise exec -- xcsift -qw --format toon'

test: ensure-ghostty embed-cli-debug embed-docs test-app

test-scripts: # Run tests for the repository's Python scripts
	@python3 -m unittest discover -s "$(CURRENT_MAKEFILE_DIR)/scripts" -p 'test_*.py'

test-app: ensure-ghostty # Run app/unit tests via xcodebuild
	@set -euo pipefail; \
	result_bundle="$(CURRENT_MAKEFILE_DIR)/build/test-results/supacode-tests.xcresult"; \
	mkdir -p "$$(dirname "$$result_bundle")"; \
	rm -rf "$$result_bundle"; \
	set +e; \
	xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" -resultBundlePath "$$result_bundle" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) SWIFT_COMPILATION_MODE=incremental 2>&1 | mise exec -- xcsift -w --format toon; \
	xcodebuild_status=$${PIPESTATUS[0]}; \
	set -e; \
	if [ "$$xcodebuild_status" -ne 0 ]; then \
		bash "$(CURRENT_MAKEFILE_DIR)/scripts/print-xcresult-failures.sh" "$$result_bundle" || true; \
		exit "$$xcodebuild_status"; \
	fi; \
	bash "$(CURRENT_MAKEFILE_DIR)/scripts/assert-xcresult-tests.sh" "$$result_bundle"

test-cli-smoke: build-cli # Smoke test CLI executable
	@set -euo pipefail; \
	bin="$$(swift build --show-bin-path)/prowl"; \
	tmp_root="$${TMPDIR:-/tmp}"; \
	tmp_dir="$$(mktemp -d "$${tmp_root%/}/prowl-smoke.XXXXXX")"; \
	trap 'rm -rf "$$tmp_dir"' EXIT; \
	help_output="$$("$$bin" --help)"; \
	version_output="$$("$$bin" --version)"; \
	echo "$$help_output" | grep -q "USAGE:"; \
	echo "$$version_output" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$$'; \
	socket="$$tmp_dir/cli.sock"; \
	response="$$tmp_dir/response.json"; \
	PROWL_CLI_SOCKET="$$socket" "$$bin" list --json >"$$response" || true; \
	jq -e '.error.code == "APP_NOT_RUNNING"' "$$response" >/dev/null

test-cli-integration: # Run CLI integration tests via SwiftPM
	@test_list="$$(swift test list)"; \
	matching_test_count="$$(printf '%s\n' "$$test_list" | grep -Ec '$(CLI_INTEGRATION_TEST_FILTER)' || true)"; \
	if [ "$$matching_test_count" -eq 0 ]; then \
		echo "error: CLI integration filter matched zero tests: $(CLI_INTEGRATION_TEST_FILTER)" >&2; \
		exit 1; \
	fi; \
	echo "CLI integration filter matched $$matching_test_count test(s)."; \
	swift test --skip-build --filter '$(CLI_INTEGRATION_TEST_FILTER)'

benchmark-build: ensure-ghostty embed-cli-debug embed-docs # Benchmark clean and compilation-cache build/test time
	@BUILD_BENCHMARK_ROOT="$(CURRENT_MAKEFILE_DIR)/.build-benchmark/build-time" \
		SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
		bash "$(CURRENT_MAKEFILE_DIR)/scripts/benchmark-build.sh" \
		"$(BUILD_BENCHMARK_SCENARIO)" "$(BUILD_BENCHMARK_SAMPLES)"

bench: ensure-ghostty embed-cli-debug embed-docs # Run performance benchmarks optimized (-O); append absolute medians to the bench log
	@set -euo pipefail; \
	bench_log_dir="$$HOME/Library/Logs/Prowl/measurements/bench"; \
	mkdir -p "$$bench_log_dir"; \
	bench_log="$$bench_log_dir/bench.jsonl"; \
	touch "$$bench_log"; \
	lines_before="$$(wc -l < "$$bench_log")"; \
	TEST_RUNNER_PROWL_BENCH_REPORT=1 \
	TEST_RUNNER_PROWL_BENCH_GIT_SHA="$$(git rev-parse --short HEAD)" \
	TEST_RUNNER_PROWL_BENCH_LOG_DIR="$$bench_log_dir" \
	xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS,arch=$$(uname -m)" \
		-configuration Release \
		-only-testing:supacodeTests/PerformanceBenchmarks \
		-parallel-testing-enabled NO \
		-derivedDataPath "$(CURRENT_MAKEFILE_DIR)/build/bench-derived-data" \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation \
		-clonedSourcePackagesDirPath $(SPM_CACHE_DIR) \
		ENABLE_TESTABILITY=YES 2>&1 | mise exec -- xcsift -w --format toon; \
	echo; \
	echo "new bench records ($$bench_log):"; \
	tail -n "+$$((lines_before + 1))" "$$bench_log" | jq -c .

measure-cpu: # Steady-state CPU + per-symbol attribution of the running Prowl Debug app (PROWL_PID=... to target)
	@bash scripts/measure-agent-detection-cpu.sh

capture-spike: # Sample the running Prowl Debug app the moment CPU crosses a threshold (THRESHOLD=150 DURATION=10)
	@bash scripts/capture-cpu-spike.sh $(or $(THRESHOLD),150) $(or $(DURATION),10)

measure-titles: # Black-box check that animated tab titles stay coalesced to ~1 change/s (works on Release builds)
	@bash scripts/measure-title-coalescing.sh

format: # Format all Swift code with swift-format (full-tree cleanup)
	swift-format -p --in-place --recursive --configuration ./.swift-format.json supacode supacodeTests

format-changed: # Format Swift files changed from FORMAT_BASE_REF (default: origin/main)
	@base="$$(git merge-base HEAD "$(FORMAT_BASE_REF)" 2>/dev/null || git rev-parse HEAD)"; \
	mapfile -t files < <( \
		{ \
			git diff --name-only --diff-filter=ACMR "$$base" -- supacode supacodeTests; \
			git ls-files --others --exclude-standard -- supacode supacodeTests; \
		} | awk '/\.swift$$/' | sort -u \
	); \
	if [ "$${#files[@]}" -eq 0 ]; then \
		echo "No changed Swift files to format."; \
	else \
		printf 'Formatting %s changed Swift file(s) from %s\n' "$${#files[@]}" "$$base"; \
		swift-format -p --in-place --configuration ./.swift-format.json "$${files[@]}"; \
	fi

format-lint: # Check Swift formatting without rewriting files
	swift-format lint --strict --recursive --configuration ./.swift-format.json supacode supacodeTests

lint: # Lint code with swiftlint
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

check: format-changed format-lint lint test-scripts # Format changed Swift files, then run swift-format lint, SwiftLint, and the script tests

log-stream: # Stream logs from the app via log stream
	log stream --predicate 'subsystem == "com.onevcat.prowl"' --style compact --color always

bump-version: # Bump app version (usage: make bump-version [VERSION=YYYY.M.DD] [BUILD=YYYYMMDD])
	@if [ -z "$(VERSION)" ]; then \
		version="$$(date +%Y.%-m.%-d)"; \
		suffix=1; \
		while git rev-parse "v$$version" >/dev/null 2>&1; do \
			suffix=$$((suffix + 1)); \
			version="$$(date +%Y.%-m.%-d).$$suffix"; \
		done; \
	else \
		if ! echo "$(VERSION)" | grep -qE '^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(\.[0-9]+)?$$'; then \
			echo "error: VERSION must be in YYYY.M.DD or YYYY.M.DD.N format"; \
			exit 1; \
		fi; \
		version="$(VERSION)"; \
	fi; \
	if [ -z "$(BUILD)" ]; then \
		base_build="$$(date +%Y%m%d)"; \
		current_build="$$(/usr/bin/awk -F' = ' '/CURRENT_PROJECT_VERSION = [0-9]+;/{gsub(/;/,"",$$2);print $$2; exit}' "$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj")"; \
		if [ "$$current_build" -ge "$$base_build" ] 2>/dev/null; then \
			build="$$((current_build + 1))"; \
		else \
			build="$$base_build"; \
		fi; \
	else \
		if ! echo "$(BUILD)" | grep -qE '^[0-9]+$$'; then \
			echo "error: BUILD must be an integer"; \
			exit 1; \
		fi; \
		build="$(BUILD)"; \
	fi; \
	sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $$version;/g" \
		"$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj"; \
	sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $$build;/g" \
		"$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj"; \
	printf '// Auto-generated by Makefile (sync-cli-version). Do not edit.\n\npublic enum ProwlVersion {\n  public static let current = "%s"\n}\n' "$$version" > \
		"$(CURRENT_MAKEFILE_DIR)/supacode/CLIService/Shared/ProwlVersion.swift"; \
	git add "$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj" \
		"$(CURRENT_MAKEFILE_DIR)/supacode/CLIService/Shared/ProwlVersion.swift"; \
	git commit -m "bump v$$version"; \
	git tag -s "v$$version" -m "v$$version"; \
	echo "version bumped to $$version (build $$build), tagged v$$version"
