#!/usr/bin/env bash

# Source this file from the Prowl repository root while using the
# self-verify-prowl skill in zsh or bash. It intentionally does not execute
# a scenario when sourced.

socket="${PROWL_SELF_VERIFY_SOCKET:-/tmp/prowl-self-verify.sock}"
cli="${PROWL_SELF_VERIFY_CLI:-./CLI/.build/debug/prowl}"
scratch_dir="${PROWL_SELF_VERIFY_DIR:-/tmp/prowl-self-verify}"

prowl_debug() {
  PROWL_CLI_SOCKET="$socket" "$cli" "$@"
}

# Return success only for the executable inside a DerivedData Debug product.
# Accept the pre-rebrand bundle name so the helper also works on older branches.
is_debug_prowl_executable() {
  case "$1" in
    */DerivedData/*/Build/Products/Debug/Prowl\ Debug.app/Contents/MacOS/ProwlApp \
      | */DerivedData/*/Build/Products/Debug/Prowl.app/Contents/MacOS/ProwlApp)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# List all debug-build ProwlApp PIDs (may include helper/child processes).
debug_pids() {
  local executable
  for pid in $(pgrep -x ProwlApp 2>/dev/null); do
    executable="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//')"
    is_debug_prowl_executable "$executable" && printf '%s\n' "$pid"
  done
}

# Compile a PID-scoped CoreGraphics window lookup helper on first screenshot use.
# Keep this CoreGraphics-based instead of osascript by default: it targets the
# debug app by PID instead of frontmost app state, window title, or UI scripting.
debug_window_id_tool() {
  local tool="$scratch_dir/window-id"
  local src="$scratch_dir/window-id.swift"
  mkdir -p "$scratch_dir"
  if [ ! -x "$tool" ]; then
    cat > "$src" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1]) ?? -1
let list = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
  if let n = w[kCGWindowNumber as String] as? Int, let name = w[kCGWindowName as String] as? String, !name.isEmpty {
    print(n)
    exit(0)
  }
}
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
  if let n = w[kCGWindowNumber as String] as? Int {
    print(n)
    exit(0)
  }
}
exit(1)
SWIFT
    swiftc "$src" -o "$tool"
  fi
  printf '%s\n' "$tool"
}

# Return the single debug PID that owns a visible window.
# macOS apps can fork helper processes that match the same path but have no
# windows; always use this for screenshot and window-level operations.
debug_pid_with_window() {
  local tool
  tool="$(debug_window_id_tool)" || return
  for pid in $(debug_pids); do
    "$tool" "$pid" >/dev/null 2>&1 && echo "$pid" && return
  done
}

debug_window_id() {
  local tool pid
  tool="$(debug_window_id_tool)" || return
  pid="${1:-$(debug_pid_with_window)}"
  [ -n "$pid" ] || return
  "$tool" "$pid" | head -1
}

wait_for_prowl_debug() {
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$socket" ] && break
    sleep 1
  done
  test -S "$socket" || return 1

  # A socket file alone can be stale. Require a live debug app and a successful
  # no-op CLI round trip before running scenario commands.
  test -n "$(debug_pids | head -1)" || return 1
  health="$(prowl_debug list --json)"
  test "$(printf '%s\n' "$health" | jq -r '.ok')" = "true" || {
    printf '%s\n' "$health" | jq -r '.error.code? // "unknown"'
    return 1
  }
}
