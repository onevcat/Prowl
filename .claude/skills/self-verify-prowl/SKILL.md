---
name: self-verify-prowl
description: Explicitly verify Prowl changes end to end in a separate Prowl Debug instance with a dedicated PROWL_CLI_SOCKET. Use only when the user explicitly requests self-verify-prowl or asks to run end-to-end verification against Prowl Debug. Do not invoke automatically after ordinary implementation work, and do not use it as a replacement for tests, make check, or make build-app.
---

# Self Verify Prowl

## Invocation Contract

Run this skill only after an explicit user request. A request to implement, fix, test, or build Prowl does not by itself
authorize this workflow.

This skill is an opt-in end-to-end layer on top of focused tests, `make check`, and `make build-app`. It launches a real
GUI app, reads shared user data, and is slower and less deterministic than those checks.

Use one of these final outcomes for every scenario:

- `PASS` — every stated assertion has direct evidence.
- `FAIL` — the observed result contradicts an assertion.
- `SKIPPED` — a declared capability or permission is unavailable, so no action was attempted.
- `INCONCLUSIVE` — the action ran, but the available evidence cannot prove or disprove the assertion.

Never turn missing evidence into `PASS`.

## Define the Scenario First

Before building or launching, write a small verification contract:

1. Setup — the worktree, initial tab or window, and required state.
2. Action — the exact CLI command or UI interaction.
3. Assertions — observable terminal text, JSON fields, accessibility state, or pixel-level result.
4. Evidence source — `prowl`, an accessibility-capable desktop tool, a PID-scoped screenshot, or a targeted log marker.
5. Cleanup — temporary tabs, panes, processes, sockets, and artifacts.

Keep scenarios narrow. “The app launched” or “the UI looks correct” is not a sufficient assertion.

## Choose the Control Surface

Use the smallest surface that can prove the assertion:

1. Use `prowl` for worktrees, tabs, panes, terminal contents, command routing, task state, and agent sessions.
2. Use the repository's `prowl-ui` skill for native UI labels, roles, enabled or selected state, navigation, sheets, menus,
   popovers, and buttons, but only after its deterministic preflight returns `READY`.
3. Use a PID-scoped screenshot only for geometry, clipping, visual hierarchy, or other pixel-level assertions.
4. Use targeted `ProwlLogger` markers only when neither public CLI state nor accessibility state exposes the behavior.

A screenshot alone does not prove that a control is enabled, selected, actionable, or wired to the intended behavior.
AppleScript coordinate loops are not an acceptable fallback. If no suitable control surface exists, report `SKIPPED` or
`INCONCLUSIVE` instead of retrying blindly.

Before writing any `prowl` command, load and read the `prowl-cli` skill. It is authoritative for JSON fields, selectors,
quoting, argument semantics, and error codes.

For a native UI scenario, run the cheap dependency gate before loading the full `prowl-ui` skill:

```bash
ui_status=0
ui_preflight="$(.claude/skills/prowl-ui/scripts/preflight.sh)" || ui_status=$?
printf '%s\n' "$ui_preflight"
```

Exit `0` means `READY`: load `.claude/skills/prowl-ui/SKILL.md` and continue. Exit `2` means `SKIPPED`: record its JSON
reason and stop that UI scenario without entering an LLM-driven interaction loop. Do not install or authorize a dependency
during self-verification.

## Preconditions

- Work from the Prowl repository root.
- Preserve unrelated user changes and never stop the user's installed Prowl app.
- Use the repo CLI (`./CLI/.build/debug/prowl`) when CLI code or protocol behavior changed.
- Treat the debug app as sharing the installed app's `~/Library` data. Do not mutate real settings unless the scenario
  explicitly requires it and restores the previous value.
- Limit read-only recovery to two short retries after a transient error. Never retry an action whose delivery is uncertain;
  observe the resulting state first.

## Launch the Separate Debug App

Use the dedicated socket `/tmp/prowl-self-verify.sock`. Clean stale artifacts, then keep `make run-app` alive in a persistent
shell or PTY for the whole run:

```bash
rm -f /tmp/prowl-self-verify.sock /tmp/prowl-self-verify.sock.lock
mkdir -p /tmp/prowl-self-verify
PROWL_CLI_SOCKET=/tmp/prowl-self-verify.sock make run-app >/tmp/prowl-self-verify/run-app.log 2>&1
```

Do not launch the `ProwlApp` executable directly from a short-lived background shell. When `PROWL_CLI_SOCKET` is set, CLI
auto-launch is disabled; every CLI call must use the same socket.

If the socket exists but the CLI returns `APP_NOT_RUNNING`, remove the stale socket and lock only after confirming no debug
`ProwlApp` process remains, then relaunch. If it returns `SOCKET_PERMISSION_DENIED`, report the sandbox limitation instead
of repeatedly reconnecting.

## Load the Helpers and Check Health

Source the bundled helpers after launch and before each later shell command:

```bash
. .claude/skills/self-verify-prowl/scripts/helpers.sh
wait_for_prowl_debug
```

The helpers provide:

- `prowl_debug` — runs the configured CLI against the dedicated socket.
- `debug_pids` — returns only Prowl executables inside a DerivedData Debug product.
- `debug_pid_with_window` and `debug_window_id` — select the visible debug window by PID.

If the helper test changed, run it directly:

```bash
bash .claude/skills/self-verify-prowl/scripts/helpers_test.sh
```

Parse JSON with direct pipes, files, or `printf '%s\n' "$json" | jq`. Do not use `echo "$json" | jq`; zsh may reinterpret
escape sequences. Invalid control characters in direct CLI output are a CLI regression, not a reason to weaken parsing.

## Drive Terminal Scenarios with Prowl CLI

Build the repo CLI when required:

```bash
make build-cli
cli="./CLI/.build/debug/prowl"
```

Seed the debug app and create a disposable tab:

```bash
opened="$(prowl_debug open . --json)"
worktree="$(printf '%s\n' "$opened" | jq -r '.data.target.worktree.id')"
created="$(prowl_debug tab create --worktree "$worktree" --json)"
pane="$(printf '%s\n' "$created" | jq -r '.data.target.pane.id')"
tab="$(printf '%s\n' "$created" | jq -r '.data.target.tab.id')"

prowl_debug send --pane "$pane" 'printf "SELF_VERIFY:%s\n" "$PWD"' \
  --capture --timeout 30 --json | jq -r '.data.capture.text'
prowl_debug read --pane "$pane" --last 80 --wait-stable --json | jq -r '.data.text'
```

Prefer pane and tab UUIDs returned by JSON over titles. A fresh debug app may be windowless, so call `open .` before
expecting `list` to contain panes.

Important JSON fields:

- `read --json`: `.data.text`
- `send --capture --json`: `.data.capture.text` and `.data.wait.exit_code`
- `list --json`: `.data.items[]`, including `.pane.id`, `.tab.id`, `.worktree.id`, and `.task.status`

For command routing, assert a unique marker, cwd, or environment value. For tab, pane, focus, or worktree behavior, compare
the targeted JSON state before and after the action. Use `agents --json` only when the changed behavior concerns Active
Agents.

## Verify UI Semantics

After the `prowl-ui` preflight is `READY`, follow that skill's Prowl-specific workflow. At minimum:

1. Resolve the debug PID with `debug_pid_with_window`, then pin the AX session to that PID.
2. Start with a compact accessibility snapshot and drill into the relevant region.
3. Act once through a fresh semantic element reference.
4. Re-snapshot the affected region or surface and assert the resulting label, value, role, state, window, or matching
   `prowl` JSON.
5. Close the AX session and restore any UI state changed by the scenario.

Do not identify the debug app by appearance: it shares data with the installed app and may look identical. If a tool cannot
pin reads and actions to the debug PID or exact window, do not use it while both instances are running.

Use headed or physical input only when the semantic action is unavailable and the scenario explicitly needs physical
delivery. If an action returns an uncertain-delivery or app-unresponsive result, inspect the new UI state before deciding
whether it failed; never repeat the action blindly.

## Use Screenshots Only for Visual Assertions

Capture only the debug app's window:

```bash
. .claude/skills/self-verify-prowl/scripts/helpers.sh
wid="$(debug_window_id)"
test -n "$wid"
screencapture -o -l"$wid" /tmp/prowl-self-verify/prowl-debug-window.png
```

Review that image only for the visual assertion declared in the scenario. A screenshot path or successful capture is not
itself a verification result.

## Use Targeted Logs Sparingly

The run log is `/tmp/prowl-self-verify/run-app.log`. Record its line count before the scenario and inspect only appended
lines after the action. Filter for a marker specific to the changed behavior; do not scan the entire log or treat generic
warnings as proof.

Logs can arrive asynchronously. One short wait and a second read is acceptable. After that, report the log assertion as
failed or inconclusive.

## Cleanup

Close every temporary tab or pane by UUID:

```bash
prowl_debug tab close --tab "$tab" --force --json
```

Stop only the DerivedData debug process:

```bash
for pid in $(debug_pids); do kill "$pid"; done
sleep 2
alive="$(debug_pids | tr '\n' ' ')"
[ -n "$alive" ] && printf 'debug still alive:%s\n' "$alive" || printf 'debug app stopped\n'
```

After the process stops, remove the dedicated socket, lock, and scratch directory. Never use `pkill -f`, and never target
`/Applications/Prowl.app`.

## Report

Report:

- The outcome (`PASS`, `FAIL`, `SKIPPED`, or `INCONCLUSIVE`) for each scenario.
- The CLI binary and UI control surface used.
- Each assertion and its direct evidence.
- Any retry, permission, or targeting limitation that affected confidence.
- Cleanup status.

Keep build, lint, and unit-test results separate from end-to-end scenario outcomes.
