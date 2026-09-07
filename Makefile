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
	$(shell find $(CLI_SOURCE_DIRS) -name .build -prune -o -type f -print 2>/dev/null)
VERSION ?=
BUILD ?=
XCODEBUILD_FLAGS ?=
BUILD_BENCHMARK_SCENARIO ?= ci
BUILD_BENCHMARK_SAMPLES ?= 1
CLI_INTEGRATION_TEST_FILTER ?= ProwlCLIIntegrationTests
FORMAT_BASE_REF ?= origin/main
BUILD_SETTINGS_CACHE := $(CURRENT_MAKEFILE_DIR)/.build_settings_cache.json
PBXPROJ_PATH := $(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj

# Release-only analytics/crash credentials. Included from Config/Secrets.env if present,
# or overridable from the environment (e.g. CI). Debug builds skip SDK init regardless.
-include Config/Secrets.env
PROWL_SENTRY_DSN ?=
PROWL_POSTHOG_API_KEY ?=
PROWL_POSTHOG_HOST ?=

# Local Debug signing. Debug products are ad-hoc signed by default, and an ad-hoc
# signature's designated requirement is its cdhash, which changes on every rebuild:
# TCC then treats each build as a new app and re-asks for Desktop/Documents/Downloads
# access from Prowl Debug and from the commands running in its panes. Setting
# PROWL_DEVELOPMENT_TEAM (environment or Config/Secrets.env) makes build-app and
# test-app sign the app and the test host with that team's Apple Development identity
# through Xcode's automatic signing, so the grants survive rebuilds. Empty keeps
# ad-hoc signing, which needs no certificate (CI, contributors).
PROWL_DEVELOPMENT_TEAM ?=
ifneq ($(strip $(PROWL_DEVELOPMENT_TEAM)),)
DEBUG_SIGNING_ARGS := DEVELOPMENT_TEAM=$(PROWL_DEVELOPMENT_TEAM)
TEST_SIGNING_ARGS := $(DEBUG_SIGNING_ARGS)
else
DEBUG_SIGNING_ARGS :=
TEST_SIGNING_ARGS := CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
endif

.DEFAULT_GOAL := help
.PHONY: build-ghostty-xcframework ensure-ghostty sync-ghostty _record-ghostty-hash build-app build-cli build-cli-release embed-cli-debug embed-cli embed-docs embed-skills run-app install-dev-build install-release archive export-archive format format-changed format-lint lint check test test-app test-scripts test-cli-smoke test-cli-unit test-cli-integration benchmark-build bump-version log-stream agent-versions
.PHONY: test-agent-contracts _test-agent-contract-codex _test-agent-contract-export

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

embed-skills: # Stage skills/ into Resources for bundling into the app (.app/Contents/Resources/skills)
	@set -euo pipefail; \
	src="$(CURRENT_MAKEFILE_DIR)/skills"; \
	dst="$(CURRENT_MAKEFILE_DIR)/Resources/skills"; \
	mkdir -p "$$dst"; \
	rsync -a --delete "$$src/" "$$dst/"; \
	echo "embedded skills at $$dst"

build-app: ensure-ghostty embed-cli-debug embed-docs embed-skills # Build the macOS app (Debug)
	bash -o pipefail -c 'xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug build -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) SWIFT_COMPILATION_MODE=incremental $(DEBUG_SIGNING_ARGS) 2>&1 | mise exec -- xcsift -w --format toon'

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
	strip -S -x "$$dst/prowl"; \
	chmod +x "$$dst/prowl"; \
	echo "embedded CLI binary at $$dst/prowl"

run-app: build-app # Build then launch (Debug) with log streaming
	@set -euo pipefail; \
	cache="$(BUILD_SETTINGS_CACHE)"; \
	pbxproj="$(PBXPROJ_PATH)"; \
	if [ -f "$$cache" ] && [ "$$cache" -nt "$$pbxproj" ]; then \
		settings="$$(cat "$$cache")"; \
	else \
		settings="$$(xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug -showBuildSettings -json 2>/dev/null)"; \
		printf '%s' "$$settings" > "$$cache"; \
	fi; \
	build_dir="$$(echo "$$settings" | jq -er '.[0].buildSettings.BUILT_PRODUCTS_DIR')"; \
	product="$$(echo "$$settings" | jq -er '.[0].buildSettings.FULL_PRODUCT_NAME')"; \
	exec_name="$$(echo "$$settings" | jq -r '.[0].buildSettings.EXECUTABLE_NAME')"; \
	if [ -z "$$build_dir" ] || [ -z "$$product" ] || [ "$$build_dir" = "null" ] || [ "$$product" = "null" ] || [ -z "$$exec_name" ] || [ "$$exec_name" = "null" ]; then \
		echo "error: failed to resolve app path from build settings"; \
		exit 1; \
	fi; \
	app_path="$$build_dir/$$product/Contents/MacOS/$$exec_name"; \
	"$$app_path"

install-dev-build: build-app # Build Debug and install to /Applications
	@set -euo pipefail; \
	cache="$(BUILD_SETTINGS_CACHE)"; \
	pbxproj="$(PBXPROJ_PATH)"; \
	if [ -f "$$cache" ] && [ "$$cache" -nt "$$pbxproj" ]; then \
		settings="$$(cat "$$cache")"; \
	else \
		settings="$$(xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug -showBuildSettings -json 2>/dev/null)"; \
		printf '%s' "$$settings" > "$$cache"; \
	fi; \
	build_dir="$$(echo "$$settings" | jq -er '.[0].buildSettings.BUILT_PRODUCTS_DIR')"; \
	product="$$(echo "$$settings" | jq -er '.[0].buildSettings.FULL_PRODUCT_NAME')"; \
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

archive: build-ghostty-xcframework embed-cli embed-docs embed-skills # Archive Release build for distribution
	bash -o pipefail -c 'xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Release -archivePath build/supacode.xcarchive archive CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$$APPLE_TEAM_ID" CODE_SIGN_IDENTITY="$$DEVELOPER_ID_IDENTITY_SHA" OTHER_CODE_SIGN_FLAGS="--timestamp" PROWL_SENTRY_DSN="$(PROWL_SENTRY_DSN)" PROWL_POSTHOG_API_KEY="$(PROWL_POSTHOG_API_KEY)" PROWL_POSTHOG_HOST="$(PROWL_POSTHOG_HOST)" -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) $(XCODEBUILD_FLAGS) 2>&1 | mise exec -- xcsift -qw --format toon'

export-archive: # Export xarchive
	bash -o pipefail -c 'xcodebuild -exportArchive -archivePath build/supacode.xcarchive -exportPath build/export -exportOptionsPlist build/ExportOptions.plist 2>&1 | mise exec -- xcsift -qw --format toon'

test: ensure-ghostty embed-cli-debug embed-docs embed-skills test-app

test-scripts: # Run tests for the repository's Python scripts
	@python3 -m unittest discover -s "$(CURRENT_MAKEFILE_DIR)/scripts" -p 'test_*.py'

test-app: ensure-ghostty # Run app/unit tests via xcodebuild
	@set -euo pipefail; \
	result_root="$(CURRENT_MAKEFILE_DIR)/build/test-results"; \
	mkdir -p "$$result_root"; \
	run_xcode_tests() { \
		local result_bundle="$$1"; \
		local action="$$2"; \
		local expected_test_count="$$3"; \
		shift 3; \
		rm -rf "$$result_bundle"; \
		if [ -n "$${PROWL_DERIVED_DATA_PATH:-}" ]; then \
			set -- -derivedDataPath "$$PROWL_DERIVED_DATA_PATH" "$$@"; \
		fi; \
		set +e; \
		xcodebuild "$$action" -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" -resultBundlePath "$$result_bundle" $(TEST_SIGNING_ARGS) -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) -showBuildTimingSummary SWIFT_COMPILATION_MODE=incremental "$$@" 2>&1 | tee "$$result_bundle.log" | mise exec -- xcsift -w --build-info --format toon; \
		local xcodebuild_status=$${PIPESTATUS[0]}; \
		set -e; \
		if [ "$$action" = "test" ] && [ -d "$$result_bundle" ]; then \
			xcrun xcresulttool get log --path "$$result_bundle" --type build --compact > "$$result_bundle.build.json" \
				|| echo "warning: could not export Xcode build metrics" >&2; \
		fi; \
		if [ "$$xcodebuild_status" -ne 0 ]; then \
			bash "$(CURRENT_MAKEFILE_DIR)/scripts/print-xcresult-failures.sh" "$$result_bundle" || true; \
			return "$$xcodebuild_status"; \
		fi; \
		if [ -n "$$expected_test_count" ]; then \
			bash "$(CURRENT_MAKEFILE_DIR)/scripts/assert-xcresult-tests.sh" "$$result_bundle" "$$expected_test_count"; \
		else \
			bash "$(CURRENT_MAKEFILE_DIR)/scripts/assert-xcresult-tests.sh" "$$result_bundle"; \
		fi; \
	}; \
	shell_cancellation_tests=( \
		"supacodeTests/ShellClientStreamingTests/cancellingRunStreamConsumerTerminatesProcessAfterItIsReady()" \
		"supacodeTests/ShellClientStreamingTests/runTerminatesReadyProcessWhenCallingTaskIsCancelled()" \
	); \
	skip_args=(); \
	only_args=(); \
	for test_id in "$${shell_cancellation_tests[@]}"; do \
		skip_args+=("-skip-testing:$$test_id"); \
		only_args+=("-only-testing:$$test_id"); \
	done; \
	run_xcode_tests "$$result_root/supacode-tests.xcresult" test "" "$${skip_args[@]}"; \
	run_xcode_tests "$$result_root/supacode-shell-cancellation-tests.xcresult" test-without-building 2 "$${only_args[@]}"

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
	jq -e '.error.code == "APP_NOT_RUNNING"' "$$response" >/dev/null; \
	mkdir -p "$$tmp_dir/skills/prowl-cli" "$$tmp_dir/home"; \
	cp "$(CURRENT_MAKEFILE_DIR)/skills/prowl-cli/SKILL.md" "$$tmp_dir/skills/prowl-cli/SKILL.md"; \
	skills_response="$$tmp_dir/skills.json"; \
	PROWL_CLI_SOCKET="$$socket" PROWL_SKILLS_DIR="$$tmp_dir/skills" HOME="$$tmp_dir/home" \
		"$$bin" skills list --json >"$$skills_response"; \
	jq -e '.ok and .data.action == "list" and (.data.skills | map(.id)) == ["prowl-cli"]' "$$skills_response" >/dev/null

test-cli-unit: # Run CLI unit tests via SwiftPM
	@test_list="$$(swift test list)"; \
	matching_test_count="$$(printf '%s\n' "$$test_list" | grep -Evc '$(CLI_INTEGRATION_TEST_FILTER)' || true)"; \
	if [ "$$matching_test_count" -eq 0 ]; then \
		echo "error: CLI unit filter matched zero tests" >&2; \
		exit 1; \
	fi; \
	echo "CLI unit filter matched $$matching_test_count test(s)."; \
	swift test --skip-build --skip '$(CLI_INTEGRATION_TEST_FILTER)'

test-cli-integration: # Run CLI integration tests via SwiftPM
	@test_list="$$(swift test list)"; \
	matching_test_count="$$(printf '%s\n' "$$test_list" | grep -Ec '$(CLI_INTEGRATION_TEST_FILTER)' || true)"; \
	if [ "$$matching_test_count" -eq 0 ]; then \
		echo "error: CLI integration filter matched zero tests: $(CLI_INTEGRATION_TEST_FILTER)" >&2; \
		exit 1; \
	fi; \
	echo "CLI integration filter matched $$matching_test_count test(s)."; \
	swift test --skip-build --filter '$(CLI_INTEGRATION_TEST_FILTER)'

benchmark-build: ensure-ghostty embed-cli-debug embed-docs embed-skills # Benchmark clean and compilation-cache build/test time
	@BUILD_BENCHMARK_ROOT="$(CURRENT_MAKEFILE_DIR)/.build-benchmark/build-time" \
		SPM_CACHE_DIR="$(SPM_CACHE_DIR)" \
		bash "$(CURRENT_MAKEFILE_DIR)/scripts/benchmark-build.sh" \
		"$(BUILD_BENCHMARK_SCENARIO)" "$(BUILD_BENCHMARK_SAMPLES)"

bench: ensure-ghostty embed-cli-debug embed-docs embed-skills # Run performance benchmarks optimized (-O); append absolute medians to the bench log
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

AGENT_VERSIONS_ARGS ?=
agent-versions: # Compare installed tier-A agent CLI versions with the managed-hook attestation (AGENT_VERSIONS_ARGS="--json" / "--strict" / "--check-matrix")
	@python3 "$(CURRENT_MAKEFILE_DIR)/scripts/agent_versions.py" $(AGENT_VERSIONS_ARGS)

AGENT_CONTRACT_ARGS ?=
test-agent-contracts: # Inventory by default; AGENT_CONTRACT_ARGS="--mode live" opts in to real model/hook checks
	@python3 "$(CURRENT_MAKEFILE_DIR)/scripts/agent_contracts.py" $(AGENT_CONTRACT_ARGS)

_test-agent-contract-codex: ensure-ghostty embed-cli-debug embed-docs embed-skills
	@: "$${PROWL_CONTRACT_CODEX_EXECUTABLE:?Use test-agent-contracts --mode preflight}" \
		"$${PROWL_CONTRACT_RECEIPT:?}" "$${PROWL_CONTRACT_NONCE:?}" "$${PROWL_CONTRACT_RESULT:?}"
	TEST_RUNNER_PROWL_RUN_LIVE_CODEX_CONTRACT=1 \
	TEST_RUNNER_PROWL_CONTRACT_CODEX_EXECUTABLE="$$PROWL_CONTRACT_CODEX_EXECUTABLE" \
	TEST_RUNNER_PROWL_CONTRACT_RECEIPT="$$PROWL_CONTRACT_RECEIPT" \
	TEST_RUNNER_PROWL_CONTRACT_NONCE="$$PROWL_CONTRACT_NONCE" \
		xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
		-resultBundlePath "$$PROWL_CONTRACT_RESULT" $(TEST_SIGNING_ARGS) -skipMacroValidation \
		-clonedSourcePackagesDirPath "$(SPM_CACHE_DIR)" SWIFT_COMPILATION_MODE=incremental \
		-only-testing:'supacodeTests/CodexConfigReadLiveContractTests/scratchPrecedenceAndProjectExclusion()' \
		2>&1 | mise exec -- xcsift -w --format toon

_test-agent-contract-export: ensure-ghostty embed-cli-debug embed-docs embed-skills
	@: "$${PROWL_CONTRACT_EXPORT_INPUT:?Use test-agent-contracts --mode live}" \
		"$${PROWL_CONTRACT_EXPORT_OUTPUT:?}" "$${PROWL_CONTRACT_NONCE:?}" "$${PROWL_CONTRACT_RESULT:?}"
	TEST_RUNNER_PROWL_CONTRACT_EXPORT_INPUT="$$PROWL_CONTRACT_EXPORT_INPUT" \
	TEST_RUNNER_PROWL_CONTRACT_EXPORT_OUTPUT="$$PROWL_CONTRACT_EXPORT_OUTPUT" \
	TEST_RUNNER_PROWL_CONTRACT_NONCE="$$PROWL_CONTRACT_NONCE" \
		xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
		-resultBundlePath "$$PROWL_CONTRACT_RESULT" $(TEST_SIGNING_ARGS) -skipMacroValidation \
		-clonedSourcePackagesDirPath "$(SPM_CACHE_DIR)" SWIFT_COMPILATION_MODE=incremental \
		-only-testing:'supacodeTests/AgentHookContractExportTests/exportPreparedLaunches()' \
		2>&1 | mise exec -- xcsift -w --format toon

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

.PHONY: check-workflow-naming
check-workflow-naming: # Check maintained workflow source and references for retired names
	python3 scripts/check_workflow_naming.py

check: format-changed format-lint lint test-scripts check-workflow-naming # Format changed Swift files, then run linters and checks

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
