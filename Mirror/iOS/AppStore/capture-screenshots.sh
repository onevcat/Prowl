#!/bin/zsh
# Capture the App Store screenshots of Prowl Mirror from the demo (docs-ai 098).
#
# Usage: Mirror/iOS/AppStore/capture-screenshots.sh <output-dir> [<iphone-udid> <ipad-udid> <duo-udid>]
#
# Builds a Release simulator app, then on each simulator: dark appearance, a 9:41 status bar,
# English locale, a fresh install, Try the Demo, and five screens. The PNGs are written without
# an alpha channel, as App Store Connect requires, to <output-dir>/{iphone,ipad,duo}/.
# Needs sim-use (screen driving, multi-display screenshots) and ImageMagick (`magick`).
# Defaults are the simulators used for the first release: iPhone 18 Pro Max (6.9"),
# iPad Pro 13-inch (M5) and iPhone Duo on its cover display.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:?usage: $0 <output-dir> [iphone ipad duo UDIDs]}"
IPHONE="${2:-DCD66428-1C05-44D6-8D63-99237C1FB3C9}"
IPAD="${3:-106A5FD9-654D-445E-9C8D-85B707B67EB0}"
DUO="${4:-C93A17C4-6052-4EDE-B82D-C4F8925E75ED}"
DERIVED="$ROOT/build/mirror-ios/screenshots-derived"
APP="$DERIVED/Build/Products/Release-iphonesimulator/ProwlMirror-iOS.app"

cd "$ROOT"
mise exec -- tuist generate --path Mirror/iOS --no-open >/dev/null
xcodebuild build -project Mirror/iOS/ProwlMirror-iOS.xcodeproj -scheme ProwlMirror-iOS -configuration Release \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO -quiet || exit 1

# The keyboard's Done item is missing from the accessibility outline on some displays (the
# iPhone Duo cover display); only a hit test finds it, so probe the right half of the screen.
hide_keyboard_by_probe() {
  local U=$1 size w h x y
  size=$(sim-use ui --device "$U" 2>/dev/null | head -1 | grep -oE '[0-9]+x[0-9]+' | head -1)
  w=${size%x*}; h=${size#*x}
  for ((x = w * 55 / 100; x < w * 85 / 100; x += 20)); do
    for ((y = h * 30 / 100; y < h * 75 / 100; y += 15)); do
      if sim-use ui --point "$x,$y" --device "$U" 2>/dev/null | grep -q '#launch-prompt-done'; then
        sim-use tap -x "$x" -y "$y" --device "$U" >/dev/null
        return 0
      fi
    done
  done
  return 1
}

capture() {
  local U=$1 DIR=$2
  local RAW="$DIR/raw"
  mkdir -p "$RAW"
  xcrun simctl boot "$U" 2>/dev/null
  xcrun simctl bootstatus "$U" -b >/dev/null 2>&1
  # The iPad status bar shows the date in the system language.
  xcrun simctl spawn "$U" defaults write "Apple Global Domain" AppleLanguages -array en-US
  xcrun simctl spawn "$U" defaults write "Apple Global Domain" AppleLocale en_US
  xcrun simctl ui "$U" appearance dark
  xcrun simctl status_bar "$U" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 >/dev/null 2>&1
  sim-use ios fold closed --device "$U" >/dev/null 2>&1   # iPhone Duo only; a no-op elsewhere
  xcrun simctl uninstall "$U" com.onevcat.prowl.mirror 2>/dev/null
  xcrun simctl install "$U" "$APP" || return 1
  xcrun simctl launch "$U" com.onevcat.prowl.mirror >/dev/null
  sleep 3
  sim-use app-state --reset --device "$U" >/dev/null 2>&1
  sim-use ios rotate portrait --device "$U" >/dev/null 2>&1
  shot() {
    sleep "${2:-1.5}"
    sim-use screenshot --device "$U" --output "$RAW/$1.png" >/dev/null 2>&1 \
      || xcrun simctl io "$U" screenshot --type png "$RAW/$1.png" >/dev/null 2>&1
    magick "$RAW/$1.png" -background black -alpha remove -alpha off -define png:color-type=2 "$DIR/$1.png"
    echo "$DIR/$1.png"
  }
  local tap=(sim-use tap --wait-timeout 10 --device "$U")
  $tap '#try-demo' >/dev/null || return 1
  shot 1-agents 2.5
  $tap '#pane-D0000000-0000-0000-0000-000000000001' >/dev/null
  shot 2-prompt 3
  $tap '#prompt-choice-1' >/dev/null
  shot 3-answered 9
  $tap '#BackButton' >/dev/null; sleep 1.5
  $tap '#pane-D0000000-0000-0000-0000-000000000002' >/dev/null; sleep 2.5
  $tap '#pane-mode' >/dev/null
  shot 4-terminal 3
  $tap '#BackButton' >/dev/null; sleep 1.5
  $tap '#new-agent-pane' >/dev/null; sleep 2
  $tap '#launch-prompt' >/dev/null
  # Paste, not type: typing goes through the simulator's input method.
  sim-use paste 'Add a Settings toggle for the compact layout, with tests.' --device "$U" >/dev/null
  sleep 1
  $tap '#launch-prompt-done' >/dev/null 2>&1 || $tap --label 'Hide keyboard' >/dev/null 2>&1 || hide_keyboard_by_probe "$U"
  shot 5-new-session 2
  rm -rf "$RAW"
}

capture "$IPHONE" "$OUT/iphone"
capture "$IPAD" "$OUT/ipad"
capture "$DUO" "$OUT/duo"
