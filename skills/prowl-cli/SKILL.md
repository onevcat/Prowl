---
name: prowl-cli
description: >-
  Use the Prowl CLI (`prowl`) to inspect or control a running Prowl GUI app and the agent sessions it hosts. Prowl runs several coding agents in parallel, each in its own pane/tab/worktree, so reach for this whenever the user wants to act on a pane other than the current one — check on, coordinate, read from, focus, send text or keys to, open, or close another pane, tab, worktree, split, window, or sibling/neighboring agent. Covers colloquial framings that never say "prowl": "check what the agent in my other window is doing", "are any of my agents running side by side still working or idle?", "tell the agent in my left split to rerun the tests", "send npm run build to the build tab and grab the output", "open ~/proj in a fresh tab", "close that scratch tab I left open". Not for ordinary editing or building inside the Prowl source repo, and not for how-to questions about Prowl's settings, preferences, or keybindings — only when the task is to actually drive panes in the live Prowl app.
---

# Prowl CLI

Use `prowl` only when the task is to inspect or control the running Prowl GUI app: read panes, check sibling agents, focus a pane, open a repo/path in Prowl, send text, or send keys. Do not use it merely because the current shell is inside the Prowl repo.

## Safe Default Workflow

For automation, always resolve a concrete pane UUID before `read`, `send`, `key`, `focus`, or destructive close commands. Text `list` and `agents` output also exposes current-process `pN` / `tN` handles for concise same-session handoffs; use them only with explicit `--pane` / `--tab` flags.

```bash
prowl list --json
```

Pick the target by `pane.id`, `tab.id`, `worktree.id`, `worktree.path`, `pane.cwd`, and `pane.focused`. Do not trust tab titles: they are free-form and can lag or lie.

When you specifically need active agent status, prefer the agent roster:

```bash
prowl agents --json
```

`prowl agents` lists detected agent panes only. It is the right starting point for "which agents are blocked/working/done?", while `prowl list` remains the all-pane inventory, including ordinary shells.

If your session was launched from a Prowl pane, the focused pane is often you. Treat focused pane IDs as something to identify and avoid unless you intentionally want to operate on yourself.

```bash
self_pane="$(prowl list --json | jq -r '.data.items[] | select(.pane.focused == true) | .pane.id')"
```

Use explicit `--pane`:

```bash
prowl read --pane "$pane" --last 80 --wait-stable --json
prowl send --pane "$pane" 'printf "PWD:%s\n" "$PWD"' --capture --timeout 30 --json
prowl focus --pane "$pane" --json
prowl key --pane "$pane" enter --json
```

## Common Recipes

Create a fresh tab for a listed worktree, then verify it is not yourself:

```bash
project="/path/to/project"
worktree="$(prowl list --json | jq -r --arg project "$project" '
  .data.items[]
  | select((.worktree.path | rtrimstr("/")) == ($project | rtrimstr("/")))
  | .worktree.id
' | head -n 1)"
pane="$(prowl tab create --worktree "$worktree" --json | jq -r '.data.target.pane.id')"
test "$pane" != "$self_pane"
```

Prefer a `worktree.id` or `worktree.name` returned by `prowl list` over a hand-typed path; list preserves normalization such as trailing slashes. Use `--path` only for the new tab's working directory inside the selected worktree.

`prowl open /path` opens or focuses a matching project/path and may create a tab when needed. It is not guaranteed to create a new pane. Use `prowl tab create` for deterministic new terminal sessions.

Run a command and capture its result:

```bash
prowl send --pane "$pane" 'git status --short' --capture --timeout 30 --json
```

Deliver input without waiting:

```bash
prowl send --pane "$pane" 'long-running command' --no-wait --json
```

Pre-fill text, then submit it later:

```bash
prowl send --pane "$pane" 'echo ready' --no-enter --no-wait --json
prowl key --pane "$pane" enter --json
```

Use this pattern only for a pane you have positively identified. If `$pane` is your own pane, `key enter` submits text into your current session.

Send multiline input from stdin:

```bash
printf '%s\n' 'echo first' 'echo second' | prowl send --pane "$pane" --capture --timeout 30 --json
```

Close a temporary tab/pane when done:

```bash
prowl pane close --pane "$pane" --json
prowl tab close --tab "$tab" --json
```

`tab close` and `pane close` require an explicit `--tab`, `--pane`, `--worktree`, or `--target`; they intentionally do not default to the currently focused pane. For automation-created tabs, prefer the `tab.id` or `pane.id` returned by `tab create`. If the target has protected agent work or a long-running command, Prowl may ask for GUI confirmation. Use `--force` only after you have positively identified the target:

```bash
prowl pane close --pane "$pane" --force --json
```

## Parsing JSON Output

Do not guess field names. Every `--json` response is `{ "ok", "command", "schema_version", "data": {...} }`, and the terminal text lives at `.data.text` — not `.content`, `.output`, or `.stdout`. Always parse with `jq` against the fields below; the authoritative, per-command field reference lives in `docs/components/cli.md`.

When JSON is stored in a shell variable, use `printf '%s\n' "$json" | jq ...`. Do not use `echo "$json" | jq`: zsh can interpret JSON escape sequences such as `\u001B` and turn them back into raw control characters.

```bash
# read: rendered terminal text is .data.text
prowl read --pane "$pane" --last 80 --wait-stable --json | jq -r '.data.text'

# send --capture: captured output is .data.capture.text; exit code is .data.wait.exit_code
out="$(prowl send --pane "$pane" 'git status --short' --capture --timeout 30 --json)"
printf '%s\n' "$out" | jq -r '.data.capture.text'
printf '%s\n' "$out" | jq -r '.data.wait.exit_code'

# tab create / open: new pane and tab ids
created="$(prowl tab create --worktree "$worktree" --json)"
printf '%s\n' "$created" | jq -r '.data.target.pane.id'
printf '%s\n' "$created" | jq -r '.data.target.tab.id'

# list / agents: ids and status
prowl list --json   | jq -r '.data.items[].pane.id'
prowl list --json   | jq -r '.data.items[] | select(.pane.focused) | .pane.id'
prowl agents --json | jq -r '.data.agents[] | "\(.status)\t\(.pane.id)"'

# guard before trusting data: bail if ok is not true
prowl list --json | jq -e '.ok == true' >/dev/null || echo "command failed"
```

Key fields by command (see `docs/components/cli.md` for the full contract):

- `read` → `.data.text`, `.data.line_count`, `.data.truncated`, `.data.mode` (`snapshot`|`last`), `.data.source` (`screen`|`scrollback`|`mixed`), plus `.data.stabilized` / `.data.waited_ms` / `.data.samples` when `--wait-stable`.
- `send` → `.data.input` (source/characters/bytes/trailing_enter_sent); `.data.wait.exit_code` and `.data.wait.duration_ms` when waiting; `.data.capture.text` / `.data.capture.line_count` / `.data.capture.truncated` when `--capture`.
- `list` / `agents` → `.data.items[]` / `.data.agents[]`, each with `.pane.id`, `.tab.id`, `.worktree.{id,name,path}`, `.task.status`.
- `tab create` / `open` → `.data.target.{pane,tab,worktree}`.

## Reading Agent Output

`task.status` is useful for coordination but is not enough to prove the screen finished rendering. `idle` can arrive before a TUI has painted its final response.

Prefer `read --wait-stable` for screen snapshots:

```bash
prowl read --pane "$pane" --last 200 --wait-stable --json
```

Most of the time `--wait-stable` alone is enough — it blocks until the screen stops changing. Only poll `task.status` first when you specifically need to wait for an agent to go from `working` back to `idle` (status flips before the TUI finishes painting, so still finish with `--wait-stable`). When polling in zsh, do not name the variable `status` — it is readonly there:

```bash
for i in 1 2 3 4 5 6; do
  task_state="$(prowl list --json | jq -r --arg p "$pane" '.data.items[] | select(.pane.id == $p) | .task.status')"
  [ "$task_state" = idle ] && break
  sleep 1
done
prowl read --pane "$pane" --last 200 --wait-stable --json
```

When you need complete output from an agent, prefer writing or redirecting to a file over reading rendered TUI output. Screen capture can be truncated or miss folded content.

For non-interactive agent CLIs, redirect stdout from the shell instead of asking the agent's tool layer to write outside its sandbox:

```bash
prowl send --pane "$pane" \
  'opencode run "Reply exactly: PROWL_OK" > /tmp/prowl-agent-out.txt' \
  --capture --timeout 120 --json
cat /tmp/prowl-agent-out.txt
```

Asking `opencode` or another agent to create `/tmp/...` itself may trigger permission prompts and fail. Shell redirection is usually simpler and more deterministic.

## Targeting Shortcuts

Find by worktree path:

```bash
prowl list --json | jq -r '
  .data.items[]
  | select(.worktree.path | rtrimstr("/") | endswith("/Prowl"))
  | .pane.id
'
```

Find focused pane, usually to exclude it:

```bash
prowl list --json | jq -r '.data.items[] | select(.pane.focused == true) | .pane.id'
```

Human scan:

```bash
prowl list --no-color
```

Find active agents, prioritizing prompts that need attention:

```bash
prowl agents --no-color
```

Get the first blocked agent pane and inspect it:

```bash
pane="$(prowl agents --json | jq -r '
  .data.agents[]
  | select(.status == "blocked")
  | .pane.id
' | head -n 1)"
prowl read --pane "$pane" --last 120 --wait-stable --json
```

When no agent is blocked, use the same pattern with `working`, `done`, or `idle` depending on the task. The JSON payload also includes `.project.name`, `.project.branch`, `.worktree.path`, `.tab.title`, and `.pane.focused`, so automation can filter by human project label while still targeting the concrete pane.

`-t/--target` can auto-resolve pane UUID, tab UUID, or worktree id/name/path, but not short handles. Explicit `--pane <uuid>` is safer for automation; explicit `--pane <pN>` is useful for a same-session human or agent handoff.

## Argument Rules

`send` and `key` positional arguments are count-sensitive:

| command | 0 args | 1 arg | 2 args |
|---|---|---|---|
| `send` | text from stdin | text to focused pane | `<target> <text>` |
| `key` | error | token to focused pane | `<target> <token>` |

Avoid positional targeting in automation. The focused pane changes after `open` and `focus`.

Important combinations:

- `send --capture` waits for completion and sends a trailing Enter. It cannot combine with `--no-wait` or `--no-enter`.
- `send --no-enter` only pre-fills text. Use `key enter` to submit later.
- `key --repeat <1-100>` repeats a token, for example `prowl key --pane "$pane" down --repeat 10`.
- Do not mix stdin input with a positional text argument.

## Quoting

Use outer single quotes when variables should expand in the target pane:

```bash
prowl send --pane "$pane" 'printf "PWD:%s\n" "$PWD"' --capture --timeout 30 --json
```

Avoid outer double quotes around payloads containing `$PWD`, `$VAR`, backticks, or command substitutions unless local expansion is intended.

## Pitfalls

- Never target by tab title alone; use `pane.id` plus path/cwd.
- Never omit `--pane` for `send`, `key`, `read`, or `focus` in automation.
- Use `prowl agents --json` for detected agent status; use `prowl list --json` for all panes and worktree-level `task.status`.
- `open /path` is a project/path navigation command. It may refocus an existing pane and is not a deterministic create command.
- Use `tab create` when automation needs a fresh shell, and capture the returned `pane.id` before sending input.
- Focused pane is not stable; `open` and `focus` change it.
- `read --wait-stable` sees rendered screen only. It cannot recover content folded by a TUI.
- `read` returning fewer lines than `--last` requested is normally `truncated: false` — the pane simply has less history and you already have it all, so do not retry for more. `truncated: true` flags a possibly-incomplete result (the full scrollback could not be read).
- `send --capture` captures a screen diff; multiline input may include command echo.
- Do not guess JSON field names. Terminal text is `.data.text` (read) and `.data.capture.text` (`send --capture`); see "Parsing JSON Output" and `docs/components/cli.md`.
- `prowl list --json | jq ...` snippets should pass shell values with `--arg`.
- In zsh, do not name variables `status`; it is readonly.
- Parser errors are not JSON even if `--json` is present, because parsing happens before command execution.
- The CLI talks to one socket owner by default. If two Prowl app instances are running, the default `prowl` command reaches whichever app owns the standard socket. For a manually launched dev instance, start the app and every CLI command with the same `PROWL_CLI_SOCKET=/tmp/name.sock`.
- Sandboxed agents must be allowed to connect to the Unix socket. `PROWL_CLI_SOCKET` is a workaround only when both the app and every CLI command use the same sandbox-accessible path.
- A newer CLI command sent to an older app can fail at transport level. If `prowl agents` returns `TRANSPORT_FAILED`, confirm the running app instance was built with the command.
- `cmd-w` can close a temporary tab, but double-check the pane first.

## Error Handling

In `--json` mode, command-level failures look like:

```json
{ "ok": false, "error": { "code": "INVALID_ARGUMENT", "message": "..." } }
```

Common codes and recovery:

- `APP_NOT_RUNNING`: Prowl is not reachable, or the socket is missing/stale. Ask before restarting the app.
- `SOCKET_PERMISSION_DENIED`: the socket exists but the sandbox or filesystem permissions blocked `connect()`. Report this as a permission/sandbox problem, not as an app-liveness problem.
- `TRANSPORT_FAILED`: the socket connection broke or the socket path is invalid (for example `ENOTSOCK` or a too-long `PROWL_CLI_SOCKET`). Recheck which Prowl instance owns the socket.
- `TARGET_NOT_FOUND` / `TARGET_NOT_UNIQUE`: run `prowl list --json` again and choose an explicit pane UUID, or refresh text `prowl list` and use its current `pN` handle.
- `EMPTY_INPUT`: `send` got neither argv text nor stdin.
- `NO_ACTIVE_PANE`: no pane resolved for positional (focused-pane) targeting; pass an explicit `--pane`.
- `INVALID_ARGUMENT`: illegal flag or flag combination, such as `--capture --no-wait`.
- `UNSUPPORTED_KEY` / `INVALID_REPEAT`: check `prowl key --help`.
- `CAPTURE_UNSUPPORTED`: `--capture` needs shell integration (OSC 133) on the target pane. Drop `--capture` and `read --wait-stable` instead, or redirect the command's output to a file (see "Reading Agent Output").
- `WAIT_TIMEOUT`: command did not finish in time; retry with `--no-wait`, or raise `--timeout`.
- `PATH_NOT_FOUND` / `PATH_NOT_DIRECTORY` / `PATH_NOT_ALLOWED`: fix the path passed to `open`.

Always check the exit code before piping output into `jq`; parser-level errors print plaintext usage to stderr.

## Handing Off Your Task

`prowl handoff to <agent> --brief -` hands your task to another agent. Run it from your own pane (the calling pane is the source — no selector needed) and pipe your briefing on stdin:

```bash
prowl handoff to codex --brief - <<'EOF'
# Handoff
## Objective
…
## Current State
…
## What Has Been Done
…
## Open Questions
…
## Risks / Watch Out
…
## Next Steps
…
## Suggested Prompt For Next Agent
…
EOF
```

To use a saved Prowl Agent Profile instead of the runtime default, ask the user
for its stable UUID and pass no runtime positional:

```bash
prowl handoff to --agent-profile-id "$profile_id" --brief - <<'EOF'
# Handoff
## Objective
…
## Current State
…
## Next Steps
…
EOF
```

The runtime positional and `--agent-profile-id` are mutually exclusive. The
Profile form rejects a positional source; use `--pane`, `--tab`, or
`--worktree` when handing off another pane. In the app, prefer choosing the
Profile by name in the Hand Off HUD — it injects the UUID and exact source pane
for you. If the user asks you to discover IDs, project only `.name`, `.id`, and
`.runtime` with `jq`; never print or paste the full
`~/.prowl/global.onevcat.json`, because environment override values may contain
credentials. Put a native Codex config profile in Prowl Profile Extra
Arguments, for example `-p work`; do not model `--profile` as an environment
variable.

Write the briefing from your current working knowledge — required sections are `## Objective`, `## Current State`, and `## Next Steps`. The receiver launches in a background tab of the same worktree; your own session stays open. A Profile handoff keeps its model, effort, mode, Extra Arguments, environment, Dedicated Home, and identity, while ignoring its manual split placement. `prowl handoff save --brief -` writes the same briefing as a checkpoint without launching anyone. Use `--no-brief` only for an intentional context-only handoff, and an explicit `--pane` to hand off a pane other than your own. Details: `docs/components/handoff.md`.

## Command Set

Current commands: `list`, `agents`, `read`, `send`, `key`, `focus`, `tab create`, `tab close`, `pane close`, `handoff to`, `handoff save`, and `open` (default). There is no CLI `quit`; close temporary tabs or panes with explicit `tab close` / `pane close` targets.
