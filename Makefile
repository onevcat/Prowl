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
VERSION ?=
BUILD ?=
XCODEBUILD_FLAGS ?=
FORMAT_BASE_REF ?= origin/main

# Release-only analytics/crash credentials. Included from Config/Secrets.env if present,
# or overridable from the environment (e.g. CI). Debug builds skip SDK init regardless.
-include Config/Secrets.env
PROWL_SENTRY_DSN ?=
PROWL_POSTHOG_API_KEY ?=
PROWL_POSTHOG_HOST ?=

.DEFAULT_GOAL := help
.PHONY: build-ghostty-xcframework ensure-ghostty sync-ghostty _check-ghostty-hash _record-ghostty-hash build-app build-cli build-cli-release embed-cli-debug embed-cli embed-docs run-app install-dev-build install-release archive export-archive format format-changed format-lint lint check test test-app test-cli-smoke test-cli-integration bump-version bump-and-release log-stream

help:  # Display this help.
	@-+echo "Run make with one of the following targets:"
	@-+echo
	@-+grep -Eh "^[a-z-]+:.*#" $(CURRENT_MAKEFILE_PATH) | sed -E 's/^(.*:)(.*#+)(.*)/  \1 @@@ \3 /' | column -t -s "@@@"

build-ghostty-xcframework: $(GHOSTTY_BUILD_STAMP) # Build ghostty framework
	@$(MAKE) _record-ghostty-hash

# Internal: actually rebuild ghostty.
$(GHOSTTY_BUILD_STAMP):
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

# Public entry point: only rebuilds ghostty if submodule SHA changed (or outputs are missing).
ensure-ghostty: _check-ghostty-hash # Ensure GhosttyKit is up-to-date (fast path when unchanged)

# Internal: compare current submodule SHA against the recorded one.
_check-ghostty-hash:
	@current_sha="$$(git -C $(CURRENT_MAKEFILE_DIR)/ThirdParty/ghostty rev-parse HEAD)"; \
	last_sha=""; \
	if [ -f "$(GHOSTTY_HASH_FILE)" ]; then \
		last_sha="$$(cat "$(GHOSTTY_HASH_FILE)")"; \
	fi; \
	artifacts_ok=1; \
	for path in "$(GHOSTTY_XCFRAMEWORK_PATH)" "$(GHOSTTY_RESOURCE_PATH)" "$(GHOSTTY_TERMINFO_PATH)"; do \
		if [ ! -e "$$path" ]; then \
			artifacts_ok=0; \
		fi; \
	done; \
	if [ "$$current_sha" != "$$last_sha" ] || [ "$$artifacts_ok" -ne 1 ]; then \
		echo "Syncing GhosttyKit for submodule $$current_sha"; \
		$(MAKE) -B build-ghostty-xcframework || exit $$?; \
		if [ "$$current_sha" != "$$last_sha" ]; then \
			rm -rf ~/Library/Developer/Xcode/DerivedData/supacode-*; \
			echo "Cleared Xcode DerivedData for ghostty header/module changes"; \
		fi; \
	else \
		echo "GhosttyKit up-to-date (SHA unchanged)"; \
	fi

# Internal: record the current submodule SHA after a successful build.
_record-ghostty-hash:
	@git -C $(CURRENT_MAKEFILE_DIR)/ThirdParty/ghostty rev-parse HEAD > "$(GHOSTTY_HASH_FILE)"

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
	bash -o pipefail -c 'xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug build -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) 2>&1 | mise exec -- xcsift -w --format toon'

sync-cli-version: # Sync app MARKETING_VERSION into ProwlCLIShared/ProwlVersion.swift
	@version="$$(/usr/bin/awk -F' = ' '/MARKETING_VERSION = [0-9.]*;/{gsub(/;/,"",$$2);print $$2; exit}' \
		"$(CURRENT_MAKEFILE_DIR)/supacode.xcodeproj/project.pbxproj")"; \
	dst="$(CURRENT_MAKEFILE_DIR)/supacode/CLIService/Shared/ProwlVersion.swift"; \
	printf '// Auto-generated by Makefile (sync-cli-version). Do not edit.\n\npublic enum ProwlVersion {\n  public static let current = "%s"\n}\n' "$$version" > "$$dst"

build-cli: sync-cli-version # Build Swift CLI binary (SPM)
	swift build --product prowl

build-cli-release: sync-cli-version # Build universal CLI binary in release mode
	swift build -c release --arch arm64 --arch x86_64 --product prowl

embed-cli-debug: build-cli # Build debug CLI and copy into Resources for dev builds
	@set -euo pipefail; \
	bin="$$(swift build --show-bin-path)/prowl"; \
	dst="$(CURRENT_MAKEFILE_DIR)/Resources/prowl-cli"; \
	mkdir -p "$$dst"; \
	cp "$$bin" "$$dst/prowl"; \
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
	settings="$$(xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug -showBuildSettings -json 2>/dev/null)"; \
	build_dir="$$(echo "$$settings" | jq -er '.[0].buildSettings.BUILT_PRODUCTS_DIR')"; \
	product="$$(echo "$$settings" | jq -er '.[0].buildSettings.FULL_PRODUCT_NAME')"; \
	exec_name="$$(echo "$$settings" | jq -r '.[0].buildSettings.EXECUTABLE_NAME')"; \
	if [ -z "$$build_dir" ] || [ -z "$$product" ] || [ "$$build_dir" = "null" ] || [ "$$product" = "null" ] || [ -z "$$exec_name" ] || [ "$$exec_name" = "null" ]; then \
		echo "error: failed to resolve app path from build settings"; \
		exit 1; \
	fi; \
	app_path="$$build_dir/$$product/Contents/MacOS/$$exec_name"; \
	"$$app_path"

install-dev-build: build-app # install dev build to /Applications
	@set -euo pipefail; \
	settings="$$(xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug -showBuildSettings -json 2>/dev/null)"; \
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

archive: build-ghostty-xcframework embed-cli embed-docs # Archive Release build for distribution
	bash -o pipefail -c 'xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Release -archivePath build/supacode.xcarchive archive CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$$APPLE_TEAM_ID" CODE_SIGN_IDENTITY="$$DEVELOPER_ID_IDENTITY_SHA" OTHER_CODE_SIGN_FLAGS="--timestamp" PROWL_SENTRY_DSN="$(PROWL_SENTRY_DSN)" PROWL_POSTHOG_API_KEY="$(PROWL_POSTHOG_API_KEY)" PROWL_POSTHOG_HOST="$(PROWL_POSTHOG_HOST)" -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) $(XCODEBUILD_FLAGS) 2>&1 | mise exec -- xcsift -qw --format toon'

export-archive: # Export xarchive
	bash -o pipefail -c 'xcodebuild -exportArchive -archivePath build/supacode.xcarchive -exportPath build/export -exportOptionsPlist build/ExportOptions.plist 2>&1 | mise exec -- xcsift -qw --format toon'

test: ensure-ghostty embed-cli-debug embed-docs test-app

test-app: ensure-ghostty # Run app/unit tests via xcodebuild
	@set -euo pipefail; \
	result_bundle="$(CURRENT_MAKEFILE_DIR)/build/test-results/supacode-tests.xcresult"; \
	mkdir -p "$$(dirname "$$result_bundle")"; \
	rm -rf "$$result_bundle"; \
	set +e; \
	xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" -resultBundlePath "$$result_bundle" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation -clonedSourcePackagesDirPath $(SPM_CACHE_DIR) 2>&1 | mise exec -- xcsift -w --format toon; \
	xcodebuild_status=$${PIPESTATUS[0]}; \
	set -e; \
	if [ "$$xcodebuild_status" -ne 0 ]; then \
		bash "$(CURRENT_MAKEFILE_DIR)/scripts/print-xcresult-failures.sh" "$$result_bundle" || true; \
	fi; \
	exit "$$xcodebuild_status"

test-cli-smoke: build-cli # Smoke test CLI executable
	@set -euo pipefail; \
	bin="$$(swift build --show-bin-path)/prowl"; \
	help_output="$$("$$bin" --help)"; \
	version_output="$$("$$bin" --version)"; \
	echo "$$help_output" | grep -q "USAGE:"; \
	echo "$$version_output" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$$'; \
	socket="/tmp/prowl-cli-smoke-$$RANDOM.sock"; \
	PROWL_CLI_SOCKET="$$socket" "$$bin" list --json >/tmp/prowl-cli-smoke.json || true; \
	jq -e '.error.code == "APP_NOT_RUNNING"' /tmp/prowl-cli-smoke.json >/dev/null

test-cli-integration: # Run CLI integration tests via SwiftPM
	swift test --filter ProwlCLIIntegrationTests

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

check: format-changed format-lint lint # Format changed Swift files, then run swift-format lint and SwiftLint

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

bump-and-release: bump-version # Bump version and push tags to trigger release
	git push --follow-tags
	@tag="$$(git describe --tags --abbrev=0)"; \
	repo="$$(gh repo view --json nameWithOwner -q .nameWithOwner)"; \
	prev="$$(gh release view --json tagName -q .tagName 2>/dev/null || echo '')"; \
	tmp=$$(mktemp); \
	if [ -n "$$prev" ]; then \
		gh api "repos/$$repo/releases/generate-notes" -f tag_name="$$tag" -f previous_tag_name="$$prev" --jq '.body' > "$$tmp"; \
	else \
		gh api "repos/$$repo/releases/generate-notes" -f tag_name="$$tag" --jq '.body' > "$$tmp"; \
	fi; \
	$${EDITOR:-vim} "$$tmp"; \
	gh release create "$$tag" --notes-file "$$tmp"; \
	rm -f "$$tmp"
