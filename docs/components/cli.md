# The `prowl` CLI

> A command-line interface to inspect and drive the running Prowl app — so you (or
> an agent) can list panes, read their screens, run commands and capture output,
> send keystrokes, focus, and open/close tabs and panes programmatically.

**Keywords:** prowl cli, command line, prowl list, prowl agents, prowl read, prowl send, prowl key, prowl focus, prowl tab, prowl pane, prowl open, telegram bot, pane id, automation, json, capture, socket

**Related:** [terminal](terminal.md) · [concepts](../concepts.md) · [active-agents](active-agents.md) · [agent-detection](agent-detection.md) · the bundled **`prowl-cli` skill** (`skills/prowl-cli/SKILL.md`)

> This is the reference for the `prowl` binary. For an opinionated, safety-first
> *workflow* guide (recipes, pitfalls, quoting), the repository also ships the
> `prowl-cli` skill at `skills/prowl-cli/SKILL.md` — same tool, task-oriented.

## What it is & when to use it

`prowl` talks to a running Prowl GUI app over a Unix socket. Reach for it whenever
the task is to act on a pane **other than the current one** — check a sibling
agent, run something in another tab and grab the output, focus a worktree, open a
project, or close a scratch tab. It is **not** for ordinary editing/building
inside a repo, and not for how-to questions about Prowl's settings.

The built-in Telegram bot uses the same command router as this CLI. Its commands
are shorter Telegram forms (`/agents`, `/list`, `/read <pane-id> [lines]`,
`/focus <pane-id>`, `/send <pane-id> <text>`, `/key <pane-id> <token>`,
`/tab_create <worktree>`, `/pane_close <pane-id>`, `/tab_close <tab-id>`), but
they resolve to the same app-side operations and target model documented here.
By default, `/send` and `/key` require a pane ID; Settings → Telegram can allow
those two commands to use the current Prowl focus instead. Close commands always
require an explicit target. Configure it in Settings → Telegram.

## Install

From the app: **Settings → Advanced → Install Command Line Tool**, or Command
Palette → "Install Command Line Tool". This symlinks `prowl` into
`/usr/local/bin` (prompting for admin if needed).

## Global options

- `--json` — emit structured JSON (recommended for automation). Each command's
  JSON has a `schema_version` like `prowl.cli.list.v1`.
- `--no-color` — disable colored text output (implied by `--json`).

Success envelope: `{ "ok": true, "command": "...", "schema_version": "...", "data": {...} }`.
Error envelope: `{ "ok": false, "command": "...", "error": { "code": "...", "message": "..." } }`.
Exit code is 0 on success, non-zero on failure. **Parser errors print plain text**
(not JSON) even with `--json`, because parsing happens before execution — always
check the exit code before piping to `jq`.

## Targeting model

Most commands accept one selector (mutually exclusive):

- `--pane <uuid>` — a specific pane (safest for automation).
- `--tab <uuid>` — a specific tab (its focused/first pane).
- `--worktree <id|name|path>` — a worktree (its selected/first tab → focused/first
  pane).
- `-t, --target <value>` — auto-resolve: tries pane UUID, then tab UUID, then
  worktree id/name/path.
- **No selector** → the *current* focus (focused worktree → selected tab → focused
  pane). Some commands (close) refuse this for safety.

**Rules:** at most one selector (else `INVALID_ARGUMENT`); prefer explicit
`--pane`. The focused pane is not stable — `open` and `focus` change it.

> **Never target by tab title.** Titles are free-form and can lie. Resolve a
> concrete `pane.id` from `prowl list --json` first.

## Commands

### `prowl list`
Snapshot of all worktrees → tabs → panes. No selectors.

```bash
prowl list --json
```
Each item contains:
- `worktree`: `id`, `name`, `path`, `root_path`, `kind` (`git`|`plain`|`workspace`)
- `tab`: `id`, `title`, `selected`
- `pane`: `id`, `title`, `cwd`, `focused`
- `task`: `status` (`running` | `idle` | null)

`task.status` is **running** when any pane in the worktree is busy — a terminal
command reporting progress, or a detected agent that is Working/Blocked (including
Claude running a background **workflow**); otherwise **idle**. See the
[worktree running indicator](agent-detection.md#worktree-running-indicator). It's
good for coordination but lags a screen by ~2–3 s and can flip to idle **before** a
TUI finishes painting — confirm with `read --wait-stable`.

Find your own pane (to avoid operating on yourself):
```bash
self_pane="$(prowl list --json | jq -r '.data.items[] | select(.pane.focused==true) | .pane.id')"
```

### `prowl agents`
Snapshot of detected agent panes, matching the Active Agents roster. No
selectors.

```bash
prowl agents --json
```
Each agent contains:
- `id`: the pane/surface UUID, suitable for `--pane`.
- `type`, `name`: normalized detector type and displayed command name. Aliases
  such as `omp` are preserved in `name`.
- `status`, `raw_state`: detected agent state. `status` is one of `blocked`,
  `working`, `done`, `idle`; `raw_state` is the lower-level detector state.
- `last_changed_at`: ISO-8601 timestamp for the most recent state change.
- `project`: display-oriented `name`, `branch`, `path` resolved from the
  agent's working directory.
- `worktree`, `tab`, `pane`: the actual terminal owner and pane metadata for
  automation.

`prowl agents` is read-only. To jump to or operate on an agent, resolve
`.data.agents[].pane.id`, then use existing commands:

```bash
pane="$(prowl agents --json | jq -r '.data.agents[] | select(.status=="blocked") | .pane.id' | head -n1)"
prowl focus --pane "$pane"
prowl read --pane "$pane" --last 120 --wait-stable
```

Text output is sorted for triage: `Blocked`, `Working`, `Done`, then `Idle`.
Empty output prints `No agents found.`.

### `prowl read [target]`
Read a pane's content.

- `--last <n>` — last N lines (scrollback + screen); omit for a full snapshot.
- `--wait-stable` — re-read until the screen stops changing (best for live TUIs).
- `--stable-interval <50–5000ms>` (default 200), `--stable-period <100–60000ms>`
  (default 800), `--wait-timeout <1–300s>` (default 10) — tune the stable wait.

```bash
prowl read --pane "$pane" --last 200 --wait-stable --json
```
Response includes `mode` (snapshot|last), `source` (screen|scrollback|mixed),
`truncated`, `line_count`, `text`, and (when waiting) `stabilized`, `waited_ms`,
`samples`. **`truncated: false` with fewer lines than `--last` just means the pane
has less history — don't retry.** `truncated: true` flags a possibly-incomplete
read.

### `prowl send [target] [text]`
Type into a pane, optionally wait for completion and capture output.

- Text source: argv, or stdin if no argv (don't provide both → `EMPTY_INPUT`).
- `--capture` — wait and capture the command's output (screen diff). **Requires
  OSC 133 shell integration** on the target; sends a trailing Enter; **cannot**
  combine with `--no-wait` or `--no-enter`.
- `--no-wait` — fire and forget.
- `--no-enter` — pre-fill text without submitting (submit later with `key enter`).
- `--timeout <1–300s>` — wait budget (default 30).

```bash
prowl send --pane "$pane" 'npm test' --capture --timeout 60 --json   # run & capture
prowl send --pane "$pane" 'long-task' --no-wait --json               # don't wait
printf '%s\n' 'echo a' 'echo b' | prowl send --pane "$pane" --capture # stdin
```
Response: `input` (source/characters/bytes/trailing_enter_sent), `wait`
(`exit_code`, `duration_ms`) when waiting, and `capture` (`text`, `line_count`,
`truncated`) when capturing. If the pane lacks shell integration you get
`CAPTURE_UNSUPPORTED` — drop `--capture` and use `read --wait-stable`, or redirect
the command's output to a file and `cat` it.

### `prowl key [target] [token]`
Send a keystroke.

- `--repeat <1–100>` — repeat the key.
- Tokens: named keys (`enter`/`return`, `esc`, `tab`, `backspace` — `delete` is an
  alias for backspace; use `delete-forward` for a forward delete — `space`, arrows
  `up`/`down`/`left`/`right`, `pageup`/`pagedown`, `home`/`end`,
  `f1`–`f12`, punctuation), single characters (`a`–`z`, `0`–`9`, etc.), and
  modifier combos joined with `-`: `cmd`/`command`, `shift`, `opt`/`option`/`alt`,
  `ctrl`/`control` — e.g. `ctrl-c`, `cmd-k`, `shift-tab`, `cmd-shift-p`.

```bash
prowl key --pane "$pane" enter --json
prowl key --pane "$pane" down --repeat 10 --json
```

### `prowl focus [target]`
Focus a worktree/tab/pane and bring Prowl to the front.

```bash
prowl focus --pane "$pane" --json
prowl focus --worktree MyApp --json
```

### `prowl tab create`
Create a new terminal tab (deterministic — unlike `open`).

- `--path <dir>` — working directory (must be inside the worktree root).
- Selectors choose the worktree (defaults to current).

```bash
pane="$(prowl tab create --worktree "$wt" --json | jq -r '.data.target.pane.id')"
```

### `prowl tab close` / `prowl pane close`
Close a tab or a pane. **Require an explicit selector** (`--tab`/`--pane`/
`--worktree`/`--target`) — they intentionally do **not** default to the focused
pane. If the target has protected agent work or a long-running command, Prowl may
ask for GUI confirmation; `--force` skips it (use only after positively
identifying the target).

```bash
prowl pane close --pane "$pane" --json
prowl tab close --tab "$tab" --force --json
```

Telegram bot close commands never pass `--force`; identify the pane/tab first,
then close it from the GUI or CLI if a forced close is needed.

### `prowl open [path]` (the default command)
Navigate Prowl to a path (or bring it to front with no argument). It may focus an
existing pane or create a tab — it is **not** a deterministic "new pane" command.
For a guaranteed fresh shell, use `tab create`.

```bash
prowl open ~/projects/app     # open/focus that project
prowl open                    # just bring Prowl forward
```
Supports `~` and `file://`. Reports `resolution` (no-argument / exact-root /
inside-root / new-root), `app_launched`, `brought_to_front`, `created_tab`, and a
`target`.

## Transport & app launch

- Socket: `~/Library/Application Support/com.onevcat.prowl/cli.sock` (override with
  `PROWL_CLI_SOCKET`). If that primary path would exceed the AF_UNIX 104-byte
  limit (e.g. a very long home-directory path), it falls back to
  `$TMPDIR/prowl-cli.sock`.
- If the app isn't running, the CLI launches it (`open -a Prowl`) and waits up to
  ~15s for the socket — except when `PROWL_CLI_SOCKET` is set.
- Sandboxed agents must be allowed to connect to the Unix socket. If the CLI
  reports `SOCKET_PERMISSION_DENIED`, allowlist the socket path in the agent
  sandbox, run `prowl` outside that sandbox, or start both the app and CLI with
  the same `PROWL_CLI_SOCKET` pointing at a sandbox-accessible path.
- Framed protocol: 4-byte length prefix + JSON, both directions.

## Error codes

| Code | Meaning / recovery |
|------|--------------------|
| `APP_NOT_RUNNING` | Prowl is not reachable, or the socket is missing/stale. Start or restart Prowl, then retry. |
| `SOCKET_PERMISSION_DENIED` | The socket exists but the client cannot connect, usually because a sandbox blocked the Unix socket. Allowlist the socket path, run outside the sandbox, or use matching `PROWL_CLI_SOCKET` values for both app and CLI. |
| `TARGET_NOT_FOUND` | Selector matched nothing — re-run `list` and pick a UUID. |
| `TARGET_NOT_UNIQUE` | Selector matched several — be more specific (use `--pane`). |
| `NO_ACTIVE_PANE` | No pane for focused-target; pass an explicit `--pane`. |
| `EMPTY_INPUT` | `send` got neither argv nor stdin (or both). |
| `INVALID_ARGUMENT` | Bad flag/combo (e.g. `--capture --no-wait`) or out-of-range value. |
| `CAPTURE_UNSUPPORTED` | Target lacks OSC 133 — drop `--capture`, use `read --wait-stable`. |
| `WAIT_TIMEOUT` | Command didn't finish in time — raise `--timeout` or use `--no-wait`. |
| `UNSUPPORTED_KEY` / `INVALID_REPEAT` | Check `prowl key --help`. |
| `PATH_NOT_FOUND` / `PATH_NOT_DIRECTORY` / `PATH_NOT_ALLOWED` | Fix the `open`/`tab create` path. |
| `LAUNCH_FAILED` | App launch or socket wait failed; the message includes the last socket diagnostic when available. |
| `TRANSPORT_FAILED` | Socket transport failed for a reason other than app availability or permission, such as `ENOTSOCK` or an invalid `PROWL_CLI_SOCKET` path. |
| `*_FAILED` (`LIST_FAILED`, `AGENTS_FAILED`, `FOCUS_FAILED`, `SEND_FAILED`, `READ_FAILED`, `TAB_FAILED`, `PANE_FAILED`, `OPEN_FAILED`) | The action itself failed. |

## Safety & self-targeting

- If your shell runs **inside a Prowl pane**, the focused pane is probably *you*.
  Identify and avoid it (the `self_pane` snippet above) so you don't `key enter`
  into your own session.
- Close commands require explicit targets and may prompt for GUI confirmation on
  protected work; `--force` bypasses the prompt.

## A complete loop (run, read, clean up)

```bash
self_pane="$(prowl list --json | jq -r '.data.items[]|select(.pane.focused==true)|.pane.id')"
pane="$(prowl tab create --worktree MyApp --json | jq -r '.data.target.pane.id')"
test "$pane" != "$self_pane"
prowl send --pane "$pane" 'swift build' --capture --timeout 300 --json
prowl read --pane "$pane" --last 100 --wait-stable --json
prowl pane close --pane "$pane" --json
```

## Gotchas for agents (quick list)

- Resolve a `pane.id` before `read`/`send`/`key`/`focus`/close — never trust tab
  titles.
- Use `prowl agents --json` when you need agent status; use `prowl list --json`
  when you need all panes, including ordinary shells.
- `--capture` needs shell integration; otherwise `read --wait-stable` or file
  redirection.
- `open` is navigation, not a guaranteed new pane — use `tab create`.
- In zsh, don't name a variable `status` (it's readonly).
- Pass shell values into `jq` with `--arg`.
