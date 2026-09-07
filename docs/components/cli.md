# The `prowl` CLI

> A command-line interface to inspect and drive the running Prowl app — so you (or
> an agent) can list panes, read their screens, run commands and capture output,
> send keystrokes, focus, and open/close tabs and panes programmatically.

**Keywords:** prowl cli, command line, prowl list, prowl agents, prowl agents read, prowl agents signal, prowl agents dispatch, prowl agents wait, prowl profiles list, prowl skills, skills install, agent skills, prowl workflow, workflow status center, workflow run panel, workflow attention, prowl read, prowl send, prowl key, prowl focus, prowl create, prowl close, prowl open, prowl handoff, pane id, agent, profile, automation, json, capture, socket

**Related:** [terminal](terminal.md) · [concepts](../concepts.md) · [active-agents](active-agents.md) · [agent-detection](agent-detection.md) · the bundled **`prowl-cli`** (`skills/prowl-cli/SKILL.md`) and **`prowl-workflow`** (`skills/prowl-workflow/SKILL.md`) skills

> This is the reference for the `prowl` binary. For an opinionated, safety-first
> *workflow* guide (recipes, pitfalls, quoting), the repository also ships the
> `prowl-cli` skill at `skills/prowl-cli/SKILL.md` — same tool, task-oriented.

## What it is & when to use it

`prowl` talks to a running Prowl GUI app over a Unix socket. Reach for it whenever
the task is to act on a pane **other than the current one** — check a sibling
agent, run something in another tab and grab the output, focus a worktree, open a
project, or close a scratch tab. It is **not** for ordinary editing/building
inside a repo, and not for how-to questions about Prowl's settings.

## Install

From the app: **Settings → Agents → CLI & Skills → Install**, or Command
Palette → "Install Command Line Tool". This symlinks `prowl` into
`/usr/local/bin` (prompting for admin if needed). The Settings page also shows
the local Unix socket path `prowl` uses to reach the app (`PROWL_CLI_SOCKET`
overrides it for both processes) and a **Status** row saying whether this app is
listening there — with the reason when it is not (typically another Prowl
instance owns the socket). Once `prowl` is installed, `prowl skills install` links
the bundled `prowl-cli` and `prowl-workflow` skills into your agents' skill folders (see
[`prowl skills`](#prowl-skills)).

## Global options

- `--json` — emit structured JSON (recommended for automation). Each command's
  JSON has a `schema_version` like `prowl.cli.list.v1`.
- `--no-color` — disable colored text output (implied by `--json`).

Success envelope: `{ "ok": true, "command": "...", "schema_version": "...", "data": {...} }`.
Error envelope: `{ "ok": false, "command": "...", "schema_version": "...", "error": { "code": "...", "message": "..." } }`.
Exit code is 0 on success, non-zero on failure. **Parser errors print plain text**
(not JSON) even with `--json`, because parsing happens before execution — always
check the exit code before piping to `jq`.

## Targeting model

Most commands accept one selector (mutually exclusive):

- `--pane <uuid|pN|N>` — a specific pane. `pN` is the short handle shown in
  text output; bare `N` is accepted too.
- `--tab <uuid|tN|N>` — a specific tab (its focused/first pane). `tN` is the
  short handle shown in text output; bare `N` is accepted too.
- `--worktree <id|name|path>` — a worktree (its selected/first tab → focused/first
  pane). For a Git worktree, `name` is the checked-out branch and stops matching after a
  checkout; automation should pass `id` (the worktree path).
- `-t, --target <value>` — auto-resolve: `pN` as a pane, `tN` as a tab, then
  pane UUID, tab UUID, or worktree id/name/path.
- **No selector** → the *current* focus (focused worktree → selected tab → focused
  pane). Some commands (close) refuse this for safety.

**Rules:** at most one selector (else `INVALID_ARGUMENT`); prefer explicit
`--pane`. The focused pane is not stable — `open` and `focus` change it.

Text `list` and `agents` output exposes short, type-prefixed handles such as
`p7` and `t6`. They are valid only for the current app process, are globally
monotonic, and are never reused after a tab or pane closes. They work in every
generic target position (`read p7`, `focus t6`, `send p7 '…'`); bare numbers remain
worktree references there. A stale prefixed handle fails rather than falling back to
a same-named worktree. JSON keeps canonical UUIDs in `id`. Neither handles nor pane
UUIDs survive an app restart (restored tabs keep their tab UUID; restored panes are new
surfaces with new UUIDs) — re-run `prowl list` instead of caching either.

> **Never target by tab title.** Titles are free-form and can lie. For scripts,
> resolve a concrete UUID `pane.id` from `prowl list --json`; for an interactive
> same-session handoff, copy the `pN` handle from text `prowl list`.

### Identity: which pane am I?

Every pane's shell starts with these environment variables, inherited by every
process launched inside it (agents, their tools, scripts):

- `PROWL_PANE_ID` — the pane's own UUID, the same value as `pane.id` in `prowl list
  --json`. Use it directly as a selector (`--pane "$PROWL_PANE_ID"`), as the anchor for
  `create pane`, and as the guard that keeps automation from acting on itself.
- `PROWL_WORKTREE_PATH`, `PROWL_ROOT_PATH` — the worktree directory and repository root
  (see [custom-actions](custom-actions.md)).

Resolve your own tab and worktree from it:

```bash
me="$(prowl list --json | jq -c --arg p "$PROWL_PANE_ID" '.data.items[] | select(.pane.id == $p)')"
if [ -z "$me" ]; then
  echo "no pane matches PROWL_PANE_ID=[$PROWL_PANE_ID] — unset, or prowl reached another Prowl instance; stop, do not guess" >&2
else
  printf '%s\n' "$me" | jq -r '.tab.id, .worktree.id, .worktree.name, .worktree.path'
fi
```

The variable is inherited, not verified: a process that scrubbed its environment
(`sudo`, `ssh`, containers) will not have it, and a tmux/screen session attached from a
different pane reports the pane its server started in. A value that matches no
`pane.id` usually means `prowl` reached a different Prowl instance than the one hosting
your pane (see [Transport & app launch](#transport--app-launch)). A match proves the pane
exists, not that you run in it: trust the value only when your process ancestry reaches
the pane's shell — under tmux/screen or a detached wrapper it names the pane the
server started in, so identify your pane by other means (`prowl agents --json` for the
pane hosting your agent session, a unique `pane.cwd`) and pass it explicitly. Keep every
step that depends on knowing yourself inside the success branch. When it is unset or
matches nothing, stop rather than guess: `pane.cwd` only narrows the candidates — several panes
usually share one cwd — and may stand in for you only when the match is unique; never
assume the *focused* pane is you. Prowl itself never trusts the variable for
attribution; commands that need the calling pane (`handoff`, `agents signal`) resolve it
from the caller's process ancestry.

## Commands

### `prowl list`
Snapshot of all worktrees → tabs → panes. No selectors.

```bash
prowl list --json
```
Each item contains:
- `worktree`: `id`, `name`, `path`, `root_path`, `kind` (`git`|`plain`|`workspace`)
- `tab`: `id`, `title`, `selected`
- `pane`: `id`, `title`, `cwd`, `focused`, `agent`
- `task`: `status` (`running` | `idle` | null)

`pane.agent` is the coding agent detected in that pane — a stable machine token
(`claude`, `codex`, `gemini`, `cursor-agent`, …) or `null` when none is detected.
It comes from the same agent detection described in
[agent-detection](agent-detection.md) and is useful for coordinating who is who
(e.g. before a [handoff](#prowl-handoff)).

These are JSON fields, so `tab.id` and `pane.id` remain UUIDs. Plain `prowl list`
instead shows `tN` for each tab and `pN` for each pane; pass either handle back
with the corresponding explicit selector:

```bash
prowl list
prowl read p7 --last 120 --wait-stable
prowl close t6 --force
```

`task.status` is **running** when any pane in the worktree is busy — a terminal
command reporting progress, or a detected agent that is Working/Blocked (including
Claude running a background **workflow**); otherwise **idle**. See the
[worktree running indicator](agent-detection.md#worktree-running-indicator). It's
good for coordination but lags a screen by ~2–3 s and can flip to idle **before** a
TUI finishes painting — confirm with `read --wait-stable`.

Your own pane is `$PROWL_PANE_ID` (see [Identity](#identity-which-pane-am-i)); gate
every action on a target behind the identity lookup result `me` from that section —
not the bare variable, which could be stale — so the check fails closed:
```bash
[ -n "$me" ] && [ "$pane" != "$PROWL_PANE_ID" ] && prowl send --pane "$pane" '…' --json
```

### `prowl agents`
Snapshot of detected agent panes, matching the Active Agents roster. No
selectors.

```bash
prowl agents --json
```
Each agent contains:
- `id`: the pane/surface UUID, suitable for `--pane`.
- `type`, `name`: normalized detector type and displayed command name. Pi uses
  `pi`; Oh My Pi uses `omp`, with `oh-my-pi` preserved as a display alias.
- `status`, `raw_state`: detected agent state. `status` is one of `blocked`,
  `working`, `done`, `idle`; `raw_state` is the lower-level detector state.
- `detection_reason`: optional stable screen-classifier explanation. A profile rule
  emits its rule ID, an ordinary profile miss emits `fallback.noRuleMatched`, and an
  unmigrated classifier emits `legacy.detector`. The field is omitted when no current
  screen result is available and never includes screen text.
- `last_changed_at`: ISO-8601 timestamp for the most recent state change.
- `project`: display-oriented `name`, `branch`, `path` resolved from the
  agent's working directory.
- `worktree`, `tab`, `pane`: the actual terminal owner and pane metadata for
  automation.
- `session`: optional native agent session metadata. When resolved, it contains
  `id`, local transcript `path` (may be null when the id comes from a non-file
  artifact), `confidence` (`exact`, `high`, or `medium`), and the evidence
  `source` (`open_file`, `process_log`, `transcript_match`, `recent_file`, or
  `store_record`). Ambiguous sessions are omitted instead of guessed. A
  `medium` session id must not be used for automatic resume without
  additional confirmation.

`prowl agents` is read-only. Text output is sorted for triage: `Blocked`,
`Working`, `Done`, then `Idle`. It prints a pane handle such as `p7`; JSON keeps
the canonical pane UUID. Either form now feeds the semantic snapshot command:

```bash
prowl agents read p7
prowl agents read p7 --json
pane="$(prowl agents --json | jq -r '.data.agents[] | select(.status=="blocked") | .pane.id' | head -n1)"
prowl agents read "$pane" --json
```

### `prowl agents read <pN|pane-uuid>`
Immediate, read-only semantic snapshot for a currently active **Codex** or
**Claude Code** pane. It requires an explicit `pN` handle or UUID from `agents`;
it never guesses from focus, accepts no worktree/tab selector, and has no wait or
timeout mode.

Default text output always reports current `Status`, classifier `Reason`, last
state-change time, and a result state. A blocked snapshot includes the raw current
interaction under `## Blocker`, preserving the question, numbered choices, selected
row, and Enter/Esc hints. It is the right command for deciding what another agent is
waiting on; use `prowl key --pane "$pane" ...` to navigate/confirm a menu or
`prowl send --pane "$pane" ...` for free-form input. Those writes are not atomic with
the read, so re-read before a consequential choice.

```bash
prowl agents read p7
prowl agents read "$pane" --max-bytes 2097152 --json
prowl agents read p7 --result-only > /tmp/agent-result.txt
```

JSON is `prowl.cli.agents.read.v1`. `.data.result.state` follows the live agent state:
`pending` whenever the agent is working or blocked — even if an earlier turn produced a
complete answer, so a read right after re-prompting a pane never returns the previous turn's
text; `complete` includes trusted `text` and appears only for an idle/done agent;
`unavailable`, `missing`, `incomplete`, and `too_large` retain a successful live snapshot but
include a reason under `.data.result.error`. Prowl reads a transcript only after a fresh `exact` or `high`
session resolution — never a `medium` candidate — and never returns partial text.

`--max-bytes` defaults to 1 MiB and accepts up to 4 MiB. `--result-only` is mutually
exclusive with `--json`; it writes exactly a complete trusted result to stdout, with
no heading or added newline. For every other result state it exits non-zero with
`SESSION_UNRESOLVED`, `RESULT_NOT_FOUND`, `RESULT_INCOMPLETE`, or
`RESULT_TOO_LARGE`. Empty `agents` roster output remains `No agents found.`.

### `prowl agents signal <event>`

Report a cooperative event for the agent in the **calling pane**:

```bash
prowl agents signal turn-ended --detail "Review complete"
prowl agents signal needs-input --session session-1 --json
prowl agents signal progress --progress 75
```

Events are `turn-ended`, `needs-input`, `session-start`, `session-end`, and `progress`.
`turn-ended` means one runtime interaction ended; it does not complete a workflow or prove
an assigned task is done. `--progress` accepts 0–100 and is valid only for `progress`.
Optional `--session` and claimed `--origin` are limited to 256 UTF-8 bytes; `--detail`
carries a short result/reason up to 32768 UTF-8 bytes. Values must be non-empty and control-free.

The command accepts no target: Prowl attributes the kernel socket peer PID through process
ancestry to a live pane. It never uses UI focus or `PROWL_PANE_ID`; external terminals,
tmux/detached ancestry, and already-closed panes fail with `SOURCE_REQUIRED` or
`AGENT_GONE`. Public signals report `source=cooperative_cli`, `confidence=exact`; exact
means explicit channel and caller-pane attribution, not verified business completion.
Claimed origin never upgrades trust. JSON uses `prowl.cli.agents.signal.v1`.

The receipt also reports whether the signal bound to the pane's current agent.
`.data.signal.binding` is `current` when the caller descends from the detected agent's launch
process (and names no other session than the one Prowl knows), or `unbound` otherwise — a
plain shell pane with no detected agent, or a runtime whose process the detector has not
resolved yet. Only a `current` signal becomes wait or dispatch evidence; an `unbound` one is
kept as diagnostics under `signals.last`, the command still exits zero, and `.data.warnings[]`
carries one `signal_unbound` item (text mode prints it once on stderr). Waits read the latest
terminal signal rather than a queue: a `needs-input` followed within one 200 ms poll by
`turn-ended` leaves only the `turn-ended` visible, so report distinct events from distinct
turns rather than back to back.

Prowl's bundled CLI has a hidden, silent native-hook ingress for managed Claude Code, Codex,
Copilot, Droid, Qoder, Pi, Oh My Pi, and OpenCode Profile launches. It is not a user command
and does not appear in help/completion. Only an app-issued in-memory token plus exact caller
ancestry, runtime, native event, launch cwd, and process generation can produce
`source=hook_claude|hook_codex|hook_copilot|hook_droid|hook_qodercli|hook_pi|hook_omp|hook_opencode`
and a
`verified_live` channel. Public `agents signal` cannot claim that provenance. Hook delivery
is bounded and fail-open for the runtime; native `turn-ended` remains observation evidence,
not dispatch or workflow completion.

### Dispatch completion and waiting

Every prompted Profile launch made by `prowl create tab|pane --profile … --prompt -`
returns a pending `data.dispatch` record. Prowl passes its opaque id only to the launched
child as `PROWL_DISPATCH_ID` and appends the completion protocol to the effective prompt.
The worker must report exactly one terminal receipt before ending its assigned turn:

```bash
prowl agents dispatch-complete --outcome succeeded --summary "Implemented and verified"
prowl agents dispatch-complete --outcome failed --summary "Blocked by an invalid fixture"
```

The required summary must be one non-empty line with no control characters and at most 32 KiB
of UTF-8. The command accepts no public dispatch id: Prowl resolves the socket caller's
process ancestry to its pane and completes *that pane's current pending dispatch*, so a
worker completes whatever it was most recently assigned even when it was launched with an
older `PROWL_DISPATCH_ID` (the variable is kept for the launch case as diagnostics only).
Outside any Prowl pane the command fails with `DISPATCH_CONTEXT_REQUIRED`; in a pane that
never held a dispatch it fails with `DISPATCH_NOT_FOUND`. Repeating an identical completion
replays the receipt; a conflicting retry is rejected. Unprompted Profile launches remain
interactive and do not create a dispatch.

A pane keeps its agent between assignments. To hand a *new* task to an agent that is already
running — a reviewer that should keep its context across rounds — dispatch into the pane
instead of launching another Profile:

```bash
prowl agents dispatch p7 --prompt - --json <<'EOF'
Round 2: re-review the diff against main. Report only findings not already fixed.
EOF
```

`--prompt -` reads the prompt from piped stdin (up to 256 KiB of UTF-8; newlines and tabs are
allowed, other control characters are rejected with `INVALID_ARGUMENT`). Prowl creates a new
pending `data.dispatch` bound to the pane and its current agent generation, then types the
prompt plus the same completion protocol a launch appends — as one bracketed paste followed by
Enter, prefixed with `[Prowl] ` so the origin is visible — through the pane's input path.
The response carries `data.target` and `data.dispatch.{id,state,created_at}` exactly like a
prompted `create`, and every wait, receipt, abandon, needs-input, incomplete, and gone rule
below applies to the new record unchanged.

Preconditions are checked before anything is typed: the pane must host a detected agent
(`AGENT_NOT_FOUND` otherwise) that is idle by the same evidence rules as
`agents wait --until idle` — a `turn-ended` the detector corroborates resolves at once; a
`turn-ended` the screen has not caught up with yet (the detector holds `working` for a few
seconds after a turn) or a detector-only idle view that still needs its two seconds of
stability is given up to five seconds to settle; a working or blocked agent without such
evidence (including a runtime `needs-input` the screen does not show) is refused with
`DISPATCH_TARGET_BUSY` rather than having text merged into its running turn. One pending
dispatch per pane: while a record is pending, a second `dispatch` fails with
`DISPATCH_PENDING` and never overwrites it; complete, abandon, or lose the previous record
first. Because a receipt can precede Codex's own `turn-ended` by a second or two, wait for
`--until idle` between rounds before dispatching again.

The coordinator waits by exact id:

```bash
prowl agents wait --dispatch "$dispatch_id" --timeout 600 --json
prowl agents wait --dispatch "$dispatch_id" --include-screen 40 --json
```

Only a successful receipt makes this command succeed. Failed, abandoned, gone,
needs-input, incomplete-turn, and timeout states return structured nonzero errors with the
immutable launch target and current receipt evidence. When `--include-screen` is requested,
that stable screen evidence remains available under `.error.details.screen` on these nonzero
outcomes. Pending receipts are memory-only,
survive pane closure as retained `gone` records, never expire automatically, and are bounded
to 256 records. A coordinator can explicitly stop tracking one without stopping its worker:

```bash
prowl agents dispatch-abandon --dispatch "$dispatch_id" --reason "Superseded assignment"
```

Abandoning a record that already completed, was abandoned, or is gone fails with
`DISPATCH_ALREADY_TERMINAL`. A closed worker pane turns its pending record into `gone` a
moment after the close, so a wait issued in that same instant may still report
`DISPATCH_INCOMPLETE`; re-run it.

For state observation rather than task proof, wait on a pane condition:

```bash
prowl agents wait p7 --until blocked --min-confidence high --timeout 120 --json
prowl agents wait "$pane" --until idle --include-screen 40 --json
```

Conditions are `idle`, `blocked`, `changed`, and `exit`. Results include their evidence
`source` and `confidence`; `observation.status` and `raw_state` always describe what the
screen detector saw at that moment, so a `turn-ended` signal can satisfy `idle` while `status`
still reads `working`. Condition waits observe state, not edges: a signal that already existed
when the wait was armed satisfies `idle` or `blocked` only if the detector agrees (idle/done,
or blocked), while a signal arriving after arming counts on its own. To wait for the *next*
turn edge rather than the current state, use `--until changed`, which needs a post-baseline
revision or a newer signal — under `auto` with a `verified_live` channel it returns at the next
runtime signal, not at a screen change. `auto` may fall back to a heuristic result — the
detector's view after the pane has remained unchanged for two seconds — only while no
covering `verified_live` channel holds a terminal signal: right after a Profile launch, when
the channel has only reported `session-start`. Once the channel holds a terminal level, that
level decides: the condition's own event (`turn-ended` for `idle`, `needs-input` for
`blocked`) resolves the wait, with detector corroboration when it predates the wait, and an
opposite event is never overridden by the screen — the wait then ends at the next runtime
signal. `changed` never falls back while such a channel exists, and neither does `exit` while
the channel can report `session-end`; a Codex or OpenCode Profile, whose channel cannot, still
resolves `exit` when the detector loses the agent for two seconds on a live surface — the
only exit evidence once `/quit` has returned the shell. When the pane hosts no detected agent yet
(typically right after launching one), the wait keeps polling for up to ten seconds, bounded
by `--timeout`, before failing with `AGENT_NOT_FOUND`. `--include-screen` samples the
detection buffer until it is stable for 800 ms (or the two-second cap), then returns the
requested trailing lines on both success and structured timeout/error details.
Strict dispatch waits never accept a visual or idle-state substitute. Closing or killing the
waiting CLI cancels its server-side subscription promptly. `turn-ended` is a runtime turn
edge; only a `dispatch-complete` receipt proves that an assigned task finished. A receipt can
also precede the runtime's own `turn-ended` by a second or two (Codex's notifier fires after
the turn), so `agents` and `agents read` immediately after a receipt may still report
`working` / `pending`.

### `prowl profiles list`

Read-only snapshot of every configured Agent Profile, including disabled profiles, in
Settings order:

```bash
prowl profiles list --json
```

Each `.data.profiles[]` item contains `id`, `name`, `enabled`, `runtime`, and
`availability`. `availability.status` is `available`, `unavailable`, or `unknown` and
reflects the login-shell executable probe only; `reason` provides optional human context.
Availability is advisory and never blocks launch. Disabled profiles remain visible but
cannot be passed to `create --profile`. Use the Profile UUID for stable automation; an
exact enabled name also works when unique.

### `prowl skills`
Link the agent skills bundled inside the Prowl app (`Prowl.app/Contents/Resources/skills/`)
into agent skill folders as directory symlinks, so every runtime reads the skill version
that matches the installed app and updates propagate automatically. The whole group is
**local-only**: it never talks to the socket, never launches the app, and works with Prowl
closed.

```bash
prowl skills list [--json]                                   # every bundled skill × target with status
prowl skills install [<skill>...] [--target <id>]... [--scope user|project] [--path <dir>]
prowl skills uninstall [<skill>...] [--target <id>]... [--scope user|project] [--path <dir>]
prowl skills path <skill>                                    # bundled directory, for scripts and workflows
```

Targets are the verified skill directories; a target is *detected* when its parent
directory exists:

| `--target` | User scope | Project scope | Read by |
|---|---|---|---|
| `claude` | `~/.claude/skills` | `<repo>/.claude/skills` | Claude Code |
| `codex` | `~/.codex/skills` | `<repo>/.codex/skills` | Codex |
| `agents` | `~/.agents/skills` | `<repo>/.agents/skills` | Codex, Gemini CLI, Cursor Agent, OpenCode, Copilot CLI, Kimi CLI, Droid, Amp, Qoder CLI, Pi, Oh My Pi, Grok Build |

- A bare `prowl skills install` links every user-installable bundled skill into every
  detected target; repeat `--target` to pick targets explicitly (an explicit target's
  directory is created even when it was not detected). Skills tagged `workflow` in `list`
  belong to workflow runs and refuse installation (`SKILL_NOT_INSTALLABLE`); `path` works
  for any bundled skill.
- Statuses: `installed` (link → this app), `not_installed`, `installed_different_source`
  (a link elsewhere, e.g. a Debug build, or a real directory), `broken` (dangling link —
  the app moved; `install` repairs it). For a foreign or dangling link, `list` also names
  where it points (`destination` in JSON, `→ path` in text), so you can tell which app owns
  the link before replacing it. Existing links are replaced; a real file or directory is
  never touched and fails the whole command with `INSTALL_CONFLICT` before anything
  changes. `uninstall` removes links only.
- `--scope project` acts on a repository: the Git root containing `--path <dir>` (or the
  current directory; worktrees included). Links never leave the repository — a target folder
  such as `.agents` that is a symlink to somewhere outside it fails with `INSTALL_CONFLICT`.
  The command prints one note: the links are absolute, Mac-specific paths and Prowl never
  edits Git state — use `.git/info/exclude` yourself if they should stay out of version
  control.

```bash
prowl skills list
prowl skills install                                 # all detected user targets
prowl skills install prowl-cli --target codex        # one skill, one target (creates ~/.codex/skills)
prowl skills install --scope project --path ~/proj   # project-scoped links
skill_dir="$(prowl skills path prowl-cli)"
```

JSON is `prowl.cli.skills.v1` with `data.action` = `list` | `install` | `uninstall` |
`path`. `list` → `.data.skills[]` with `id`, `name`, `description`, `audience`, `path`,
and `targets[]` (`id`, `detected`, `path`, `status`, optional `destination`); `install`/`uninstall` →
`.data.scope`, `.data.root`, `.data.results[]` (`skill`, `target`, `path`, `before`,
`after`) and, for project scope, `.data.note`; `path` → `.data.skill.{id,name,audience,path}`.
`PROWL_SKILLS_DIR` points the command at a different skills root for development.
Settings › Agents › CLI & Skills › **Agent Skills** offers the same user-scope actions
from the GUI (Install / Remove / Repair / Replace per skill × detected target) and shows
the same status as `prowl skills list` — see [settings](settings.md#agent-skills).

### `prowl workflow`
Discover, validate, and **run** Agent Workflow definitions — `.pwlworkflow` bundles
(`schema: prowl.workflow/v1`) that declare a multi-agent flow Prowl runs (roles, `message` /
`launch` steps with expected outputs, typed state, nested conditions/loops, and built-in/local actions). Definitions come from
three sources, later ones winning for the same id: the app bundle
(`Prowl.app/Contents/Resources/workflows/`, ids `prowl.*` are reserved for it) <
`~/.prowl/workflows/*.pwlworkflow` < `<repo>/.prowl/workflows/*.pwlworkflow`. `validate` and `schema` run
**locally** and work with Prowl closed; every other subcommand needs the app. The bundled
`prowl-workflow` skill (`skills/prowl-workflow/SKILL.md`, linked by `prowl skills install`)
teaches an agent to author, validate, run, and take part in workflows. The feature as a
whole — entry points, the start sheet, the run panel, Settings → Agents → Workflows — is in
[workflows](workflows.md).

```bash
prowl workflow list [target] [--json]                   # every definition visible to a worktree, with status
prowl workflow run <id|name> [source] [--role r=<binding>]... [--input k=v]... [--skip <step>]... [--json]
prowl workflow test-action <workflow> <action> [source] --input-json '<JSON object>' [--json]
prowl workflow status [run-id] [--json]                 # no args: the calling pane's run, role, awaited step
prowl workflow deliver [-|--file <path>] [--verdict <v>] [--token <t>] [--run <id> --step <id>] [--force] [--json]
prowl workflow cancel <run-id> [--json]
prowl workflow validate <bundle.pwlworkflow> [--scope bundle|user|repo] [--json]   # validate a bundle; exit 1 on errors
prowl workflow schema [--action] [--json]                          # workflow or action manifest JSON Schema (Draft 2020-12)
```

- `list` searches the repo source of one worktree: the caller's own pane's worktree, else the
  focused worktree, or any target (`pN`/`tN`/UUID/worktree id/name/path, or `--worktree`,
  `--tab`, `--pane`, `--target`). Without a resolvable worktree only the bundle and user
  sources are searched. Each `.data.workflows[]` item carries `id`, `name`, `description`,
  `scope` (`bundle` | `user` | `repo`), `path`, `enabled`, `valid`, `errors`, `warnings`, and
  `shadowed` (a higher-precedence source defines the same id, so this file is not the one
  that runs). A file that does not parse is listed with `valid: false` and no `id`. Invalid
  files never shadow valid ones.
- `run` starts the effective (unshadowed, valid, enabled) definition with that id or unique
  name. A workflow with a `current` role runs **from a pane**: the caller's own pane by
  default, or an explicit `pN` / pane UUID; outside a pane it fails with `SOURCE_REQUIRED`. A
  workflow without one runs in a worktree (the caller's, the focused one, or an explicit
  worktree target). Bindings are frozen before anything happens: `--role <launch role>=<profile
  name|UUID|auto>` (else the remembered profile for that role, then a profile matching the
  role's `suggest`, then the repository's Recommended profile — `PROFILE_NOT_FOUND` when nothing
  qualifies, `PROFILE_NOT_UNIQUE` for an ambiguous name; an override the role rejects is logged
  and falls through), `--role <pick role>=<pN|pane UUID>` (required; an agent pane of the same
  worktree that is not the source pane), `--input name=value` for declared inputs, `--skip
  <step>` for steps whose output nothing else needs. A pane belongs to at most one active run
  (`PANE_BUSY`) and must not still hold a pending dispatch (`DISPATCH_PENDING`: an activation is
  a dispatch record and a pane holds one at a time — complete or abandon it first). The
  response is the run (`.data.id`, `.data.status`, `.data.step`, frozen
  `.data.bindings`, `.data.run_directory`); when the run was started from the pane that is
  its `current` role and the first step messages that role, `.data.self_initiated` carries the
  line the runner would have typed (scoped read and completion commands included) and
  nothing is typed into the caller — read it and follow it yourself. The run directory is
  `~/.prowl/logs/workflow-runs/<root-name>-<root-hash>/YYYY-MM/<run-id>/`, including
  its frozen bundle and all runtime artifacts. The UUID remains searchable after the
  execution root is closed, moved, or deleted. See [history retention](workflows.md).
- `read [resource-id] --run <run-uuid> --invocation <number>` retrieves the assigned
  instruction (default) or a resource ID returned with it. Prowl checks the caller pane,
  run, and invocation against the current task assignment. Reads need no token.
  Normal completion keeps the last task readable until reassignment, history cleanup,
  or app exit; cancellation, Skip, and activation revocation revoke access. `--json` returns `body`, `encoding`
  (`utf-8` or `base64`), `resources`, `invocation`, `offset`, `next_offset`, and `total_bytes`.
  Reads return at most 256 KiB. Continue with `--offset <next_offset>` until `next_offset` is absent;
  decode each chunk according to its encoding and concatenate its bytes. Resources
  include only assigned skills and explicitly passed workflow inputs/artifacts. A granted
  artifact directory returns a JSON list of its contained file IDs; read each ID separately.
  Reading content never delivers an output or completes a step.
- `deliver` delivers the output of the step this pane is working on: the body comes from piped
  stdin (`-`) or `--file`; `--verdict` supplies the declared verdict when the step requires
  one. Prowl attributes the delivery by the **caller pane** (its pending workflow activation) and
  checks the token the step handed out (`PROWL_WORKFLOW_TOKEN=… prowl workflow deliver -` for a
  typed step, the child environment of a launched role, or `--token`): a stale or wrong token
  is `TOKEN_INVALID`, a missing one `TOKEN_REQUIRED`, a pane whose step moved on
  `STEP_NOT_EXPECTING`. `--run <id> --step <step>` is the manual path from outside the role's
  pane (no token needed); when the calling pane is itself waiting for a different step, the
  explicit target needs `--force` (`ROLE_MISMATCH` otherwise). The command answers only after
  the output is in the run directory: `.data.delivery.state` is `delivered` (the run advanced)
  or `provisional` — the body had issues a non-strict step tolerates (missing sections, an
  undeclared verdict, …), listed in `.data.delivery.warnings[]`; it is on disk but the run waits
  for a decision in Prowl (accept, ask again, skip). Empty bodies are `OUTPUT_INVALID`, bodies
  above the step's cap `OUTPUT_TOO_LARGE`, and `strict: true` steps reject issues outright.
  `agents dispatch-complete` from a pane that owes a workflow delivery is refused with
  `WORKFLOW_DELIVERY_REQUIRED` and the exact `deliver` command to run instead.
- `status` without an argument answers "who am I": the calling pane's active run, its role,
  the step in progress, and — for the role that owes it — the awaited output with its
  requirements and completion commands (`.data.activation`). With a run UUID it reports that
  run, live or, after an app restart, from its `run.json` (`.data.source` is `live` or
  `record`; a record has no activation and no tokens). Runs an earlier app instance left
  unfinished are marked `interrupted` at launch; V1 does not resume them.
- While a run is active in the selected worktree, the toolbar's center status item shows its
  current step (and the active-run count when several runs share the worktree). Hover previews the
  run panel; click keeps it open. The panel lists all active runs in that worktree, their role panes,
  repeat rounds and steps, the current instruction, run folder and log. A role chip focuses its
  exact pane. When a run needs attention, the panel exposes every recovery the runner currently
  permits: Focus Pane, Nudge Again, Keep Waiting, Retry, Relaunch Role, Accept as Delivered,
  Accept with a declared verdict, Ask Again, Skip Step, and Cancel Run as applicable. Skip shows
  whether the workflow continues or ends before confirmation. Successful completion uses the
  toolbar success toast; background attention/completion also enters Notifications and focuses the
  relevant pane when selected. When that worktree is already being viewed, the existing active-
  surface notification preference decides whether external delivery stays quiet.
- `cancel <run-id>` stops a live run: it stops advancing and injecting, abandons the pending
  activation, keeps every pane and output, and reports the ended run. Attention states a run
  reaches (an agent that went idle without delivering, a blocked or vanished pane, a
  provisional delivery, a failed launch) are visible through `status` and the toolbar run panel.
- `validate` prints every diagnostic as `path:line:column: error[code]: message` (warnings
  likewise) and ends with `OK <id> (<name>)` or `INVALID …`. Errors make the command fail
  with `WORKFLOW_INVALID`; in JSON the full validate payload (`path`, `valid`, `workflow`,
  `diagnostics[]` with `severity`, `code`, `message`, optional `line`/`column`) is under
  `.error.details`, and a valid file returns it under `.data`. The scope decides whether a
  `prowl.*` id is allowed; it is inferred from the file's directory (`~/.prowl/workflows` →
  user, any other `.prowl/workflows` → repo, elsewhere → user) unless `--scope` says
  otherwise. When the `prowl` binary is not inside an app bundle (a development build with
  `PROWL_SKILLS_DIR` unset), `skill:` references cannot be checked and are reported as
  `skill_unchecked` warnings instead of errors.
- `schema` prints the machine-readable definition schema for editors and authoring agents
  (`--json` wraps it as `.data.schema`). Structural rules live in the schema; cross-reference
  rules (undefined roles, premature `{{ deliveries.* }}`, loop verdicts, …) are enforced by
  `validate` only.

```bash
prowl workflow validate .prowl/workflows/review.pwlworkflow
prowl workflow list --json | jq '.data.workflows[] | select(.valid) | .id'
run="$(prowl workflow run review --role reviewer=Codex --input max_rounds=3 --json)"
printf '%s\n' "$run" | jq -r '.data.self_initiated.line'      # what to do now, when this pane is the current role
prowl workflow status --json | jq '.data.activation'           # what this pane owes, and how to deliver it
PROWL_WORKFLOW_TOKEN=… prowl workflow deliver - <<'EOF'
## Scope
…
EOF
prowl workflow cancel "$(printf '%s\n' "$run" | jq -r '.data.id')"
```

JSON is `prowl.cli.workflow.v1` with `data.action` = `list` | `run` | `status` | `deliver` |
`cancel` | `read` | `validate` | `schema`; `run`, `status`, and `cancel` share the run shape, `deliver`
nests it under `.data.run` beside `.data.delivery`.

`prowl workflow test-action <workflow> <action> [source] --input-json '<JSON object>' [--json]`
starts a real single-action run from a discovered bundle. Use `builtin:collect-worktree-context` or
`local:<id>`. Script bundles require prior native approval in Settings > Agents > Workflows;
`WORKFLOW_APPROVAL_REQUIRED` tells you to review the bundle. This command cannot grant approval.
It uses the same worktree, fixed bundle copy, process limits, cancellation, and action records
as a workflow run. Poll the returned run ID with `workflow status` and inspect its run directory.

`validate` accepts the bundle directory, not its `workflow.yaml`. Loose YAML files are not workflow bundles. See [Workflows](workflows.md#script-actions-and-bundles) for approval and results.

### `prowl read [target]`
Read a pane's content.

- `--last <n>` — last N lines (scrollback + screen); omit for a full snapshot.
- `--source <viewport|detection>` — `viewport` preserves the normal read behavior
  (default); `detection` reads the exact active-screen buffer used by agent-state
  detection, which can differ from the viewport when a pane is scrolled. If the
  running app is too old to honor `detection`, the CLI fails with `READ_FAILED`
  instead of returning viewport text; update or restart Prowl and retry.
- `--wait-stable` — re-read until the screen stops changing (best for live TUIs).
- `--stable-interval <50–5000ms>` (default 200), `--stable-period <100–60000ms>`
  (default 800), `--wait-timeout <1–300s>` (default 10) — tune the stable wait.

```bash
prowl read --pane "$pane" --last 200 --wait-stable --json
```
Response includes `mode` (snapshot|last), `source`
(screen|scrollback|mixed|detection), `truncated`, `line_count`, `text`, and (when
waiting) `stabilized`, `waited_ms`, `samples`. **`truncated: false` with fewer
lines than `--last` just means the pane has less history — don't retry.**
`truncated: true` flags a possibly-incomplete read.

For detector regression captures, omit `--last`, require the returned source, and
extract the JSON string without adding a newline:

```bash
# Run from the Prowl source checkout so the private staging path is ignored.
repo_root="$(git rev-parse --show-toplevel)"
test -f "$repo_root/supacode.xcodeproj/project.pbxproj"
staging="$repo_root/.local/agent-screen-captures"
mkdir -p "$staging"
capture="$(prowl read --pane "$pane" --source detection --json)"
printf '%s\n' "$capture" | jq -e '.data.source == "detection"' >/dev/null
printf '%s\n' "$capture" | jq -j '.data.text' > "$staging/raw-capture.txt"
```

This is a diagnostic/capture source, not a more complete terminal-history read;
normal pane inspection should keep the default viewport source.

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

### `prowl create tab`
Create a new terminal tab (deterministic — unlike `open`). A worktree is required,
either positionally or with `--worktree`; `--path` must remain inside it.

```bash
pane="$(prowl create tab "$wt" --json | jq -r '.data.target.pane.id')"
```

Without `--profile`, the new tab always takes focus (`--background` is Profile-only), so
keystrokes a person is typing at that moment land in the new shell; while someone is working
in the app, prefer a Profile launch with `--background`.

Add `--profile <name|uuid>` to launch an enabled Agent Profile instead of a shell. An
optional kickoff prompt uses the sole stdin spelling `--prompt -`:

```bash
pane="$(
  prowl create tab "$wt" --profile Reviewer --prompt - --json <<'EOF' | jq -r '.data.target.pane.id'
Review the current diff and report actionable findings.
EOF
)"
```

`--prompt -` requires a pipe or heredoc; it rejects interactive stdin instead of waiting
for `Ctrl-D`. Prowl carries the prompt outside the terminal's initial PTY input and expands
it as one quoted argument, so multiline, tab-containing, and long review instructions are
not interpreted by the shell line editor. The portable typed command runs unchanged in zsh,
bash, and fish; it removes the carrier from the Profile process environment, while the pane
shell retains the reserved carrier. NUL bytes remain invalid, and UTF-8 prompt input over
256 KiB is rejected before creating a surface. For larger requirement sets, keep the content
in a repository file and use the kickoff prompt to tell the Profile which file to read.

`--background` is Profile-only and creates the tab without changing the selected
worktree, tab, or pane.

Claude Code, Codex, GitHub Copilot, Droid, Qoder, Pi, Oh My Pi, and OpenCode Profile launches
complete managed-signal preflight before a dispatch slot or surface is created. Safe preparation
failure launches the original argv unchanged.
JSON success then includes one optional `.data.warnings[]` item with
`code=managed_hook_degraded`; text mode keeps launch output on stdout and renders the warning
exactly once on stderr. No warning array is encoded when empty, and degradation never changes
receipt semantics.

### `prowl create pane`
Create a split beside an explicit pane anchor. The anchor is a pane UUID or current-process
`pN` handle, supplied positionally or with `--pane`; `--direction` is required.

```bash
pane="$(prowl create pane "$anchor" --direction right --json | jq -r '.data.target.pane.id')"
```

Directions are `right`, `left`, `up`, and `down`. Without `--profile`, the created pane
inherits the anchor's working directory and terminal configuration, becomes focused in that
tab, and is returned as `.data.target.pane.id`. Like `create tab`, the command selects the
anchor's worktree and tab. With `--profile`, it launches the selected Profile and may take a
kickoff prompt from `--prompt -`; `--background` inserts the split without focusing it or
selecting a hidden anchor's worktree/tab.

`.data.anchor` (`.data.anchor.pane.id`) records the source pane as resolved before the split
(its `focused` flag is pre-split state), `.data.direction` records the public direction, and a
Profile launch adds
`.data.launch.{profile_id,profile_name,agent}`. The CLI requires this metadata for
`--profile`, so an older app cannot silently return an ordinary shell. A mismatch error warns
that the older app may already have created a resource; inspect `prowl list` and close it
before retrying. The operation targets the anchor directly; it never depends on current UI
focus.

### `prowl close`
Close one explicit tab or pane. The positional form uses a UUID, `pN`, or `tN`; the
long forms are `--pane <uuid|pN|N>` and `--tab <uuid|tN|N>`. `close` rejects
worktree targeting and has no focus fallback. Protected agent work or a long-running
command may trigger GUI confirmation; `--force` skips it only after positive
identification.

```bash
prowl close "$pane" --json
prowl close --tab "$tab" --force --json
```

> `prowl tab create`, `prowl tab close`, and `prowl pane close` are deprecated
> compatibility aliases. They warn on stderr and will be removed after one release.

### `prowl open [path]` (the default command)
Navigate Prowl to a path (or bring it to front with no argument). It may focus an
existing pane or create a tab — it is **not** a deterministic "new pane" command.
For a guaranteed fresh shell, use `create tab`.

```bash
prowl open ~/projects/app     # open/focus that project
prowl open                    # just bring Prowl forward
```
Supports `~` and `file://`. Reports `resolution` (no-argument / exact-root /
inside-root / new-root), `app_launched`, `brought_to_front`, `created_tab`, and a
`target`.

### `prowl handoff`
Hand a task off between agents: archive the outgoing state under the target's
`.prowl/handoff/`, install a fresh agent-authored briefing, and launch the
receiver in a background tab. Centred on [workspaces](workspaces.md), but works
for any runnable target. Two subcommands:

```bash
prowl handoff to <agent> [target] [--brief -|--no-brief] [--note "…"] [--no-launch]
prowl handoff save       [target] [--brief -|--no-brief] [--note "…"]
```

**Source resolution.** An explicit selector (`--pane p3`, `--tab t2`,
`--worktree <name>`, or the positional target) wins; otherwise the source is
**the calling pane** — Prowl maps the `prowl` process's ancestry to the pane
whose shell spawned it, so an agent running the command hands off *itself*
regardless of UI focus. Outside any Prowl pane — or when the ancestry does not
reach the pane's shell, as under tmux/screen or a detached wrapper — a call with no
selector errors with `SOURCE_REQUIRED`; in those same setups `$PROWL_PANE_ID` is not a
trustworthy stand-in (it names the pane the server started in), so determine the pane
by other means and pass it with `--pane` explicitly. The focused pane is never guessed.

**Briefing.** `--brief -` reads an inline agent-authored briefing from stdin
(heredoc). Every handoff must provide it or use `--no-brief` as the explicit
context-only escape; otherwise the command errors (`BRIEF_REQUIRED`) with a
copy-pasteable example and zero side effects. A briefing must
contain at least `## Objective`, `## Current State`, and `## Next Steps`; an
invalid inline brief errors (`INVALID_BRIEF`) with **zero side effects**. Prowl
never resumes the source session or starts a hidden model turn, including when
the caller targets another pane.

- **`to <agent>`** — archives the current artifact to
  `.prowl/handoff/archive/<ts>-<from>-to-<to>.md` **first**, installs the
  fresh briefing as `current.md` (or removes a stale one when the transition
  is context-only), regenerates `context.md` from live git state, and launches
  the receiver in a **background tab** — no worktree switch, no focus steal; a
  notification announces the completed handoff unless you are already watching
  that worktree. The kickoff prompt adapts to whether a briefing exists. An
  observed unrestricted source execution policy carries over between the
  verified Claude Code and Codex adapters for the destination launch only;
  model identifiers remain with their original agent family. Interactive
  launch is verified for `claude` and `codex`; `--no-launch` still archives +
  saves and accepts the full detected-agent list: `pi`, `omp`, `claude`, `codex`,
  `gemini`, `cursor-agent`, `cline`, `opencode`, `copilot`, `kimi`, `droid`,
  `amp`, `qodercli`, `qwen`, `grok`.
- **`save`** — a deferred-handoff checkpoint: installs a fresh briefing
  (archiving the replaced one) and regenerates `context.md`, with no
  destination and no launch. A context-only `save --no-brief` refreshes
  generated state without touching the last valid briefing.

```bash
prowl handoff to codex --brief - <<'EOF'      # self-handoff with inline briefing
# Handoff
## Objective
…
## Current State
…
## Next Steps
…
EOF
prowl handoff save --brief - --note "eod checkpoint" <<'EOF' … EOF
prowl handoff to claude --pane p7 --no-brief --json  # third pane, generated context only
```

The outgoing agent is whatever Prowl detects in the source pane (see
`pane.agent` in [`list`](#prowl-list)). Response payload
(`prowl.cli.handoff.v2`) includes `action`, `artifact_path`, `outgoing_agent`,
`to_agent`, `repos`, `changed_file_count`, `archived_path`, `session_context`,
`briefing` (`inline` / `none`), `has_briefing`, and
`launched_pane`. `session_context` includes the generated excerpt path plus
native `session_id` / `transcript_path` only when the source pane has
unambiguous native-session evidence (the same identity exposed by
`prowl agents`); ambiguous sessions are never forked. `current.md` exists iff
a validated briefing produced it — there is no template and nothing to
maintain between handoffs. Full feature guide: [handoff](handoff.md).

The generated `.prowl/handoff/` directory contains its own `.gitignore`, so its
artifacts and terminal excerpts do not appear in `git status`.

## Transport & app launch

- Socket: `~/Library/Application Support/com.onevcat.prowl/cli.sock` (override with
  `PROWL_CLI_SOCKET`). If that primary path would exceed the AF_UNIX 104-byte
  limit (e.g. a very long home-directory path), it falls back to
  `$TMPDIR/prowl-cli.sock`.
- If the app isn't running, the CLI launches it (`open -a Prowl`) and waits up to
  ~15s for the socket — except when `PROWL_CLI_SOCKET` is set.
- A separately launched (Debug) app needs both its own `PROWL_CLI_SOCKET` and the CLI
  built with it (`./.build/debug/prowl` from that checkout, or
  `Prowl Debug.app/Contents/Resources/prowl-cli/prowl`); the installed `prowl` may
  report the same version yet lack newer commands.
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
| `TARGET_NOT_FOUND` | Selector matched nothing — re-run `list` and pick a UUID or current short handle. |
| `TARGET_NOT_UNIQUE` | Selector matched several — be more specific (use `--pane`). |
| `PROFILE_NOT_FOUND` | No enabled Profile matches the UUID or exact name — re-run `profiles list`; disabled Profiles cannot launch. |
| `PROFILE_NOT_UNIQUE` | Several enabled Profiles have the exact name — use the Profile UUID from `profiles list`. |
| `AGENT_NOT_FOUND` / `AGENT_UNSUPPORTED` | `agents read` target no longer hosts an agent, or it is not Codex/Claude Code; `agents wait <pane> --until …` saw no detected agent within its ten-second appearance grace; `agents dispatch` targeted a pane with no detected agent. Re-run `agents`. |
| `DISPATCH_NOT_FOUND` | No dispatch record matches `--dispatch`, or `dispatch-complete` ran in a pane that never held one; records are memory-only and reset on app restart. |
| `DISPATCH_CONTEXT_REQUIRED` | `dispatch-complete` ran from a process outside any Prowl pane (tmux/detached wrapper, another terminal), so no pane could own the receipt. |
| `DISPATCH_PENDING` | `agents dispatch` refused: the pane already holds a pending dispatch (`.error.details.record`). Wait for it, or `dispatch-abandon` it, before dispatching again. |
| `DISPATCH_TARGET_BUSY` | `agents dispatch` refused: the pane's agent is working or blocked (`.error.details.observation`, `.signals`). Wait for `--until idle`, then retry. |
| `DISPATCH_ALREADY_TERMINAL` | `dispatch-abandon` targeted a record that already completed, was abandoned, or is gone. |
| `DISPATCH_FAILED` / `DISPATCH_ABANDONED` / `DISPATCH_NEEDS_INPUT` / `DISPATCH_INCOMPLETE` | `agents wait --dispatch` structured outcomes; `.error.details` retains the record, target, and evidence (see **Dispatch completion and waiting**). |
| `SOURCE_REQUIRED` | A caller-owned command such as `agents signal`, selector-free `handoff`, `workflow run` of a workflow with a `current` role, `workflow status` without a run id, or `workflow deliver` without `--run --step` could not map the socket peer ancestry to a Prowl pane. Run it inside the source pane without tmux/detached wrappers, or use an explicit selector where that command permits one. |
| `AGENT_GONE` | The meaning is mode-specific: a signal caller disappeared, a dispatch worker became terminal, or a generic condition target closed. Inspect `.error.details.mode`; dispatch details retain a record, while condition details retain the requested condition and exact surface observation. |
| `BLOCKER_UNREADABLE` | A blocked screen was detected but Prowl could not safely extract its current interaction text. Re-run `agents read` or inspect with `read`. |
| `SESSION_UNRESOLVED` / `RESULT_NOT_FOUND` / `RESULT_INCOMPLETE` / `RESULT_TOO_LARGE` | `agents read --result-only` could not provide one trustworthy complete result. Drop `--result-only` to retain the live snapshot and inspect `.data.result`. |
| `SKILL_NOT_FOUND` / `TARGET_NOT_FOUND` (`skills`) | No bundled skill or supported target with that id — re-run `prowl skills list`. A bare `skills install` also reports `TARGET_NOT_FOUND` when no target directory is detected; pass `--target`. |
| `SKILL_NOT_INSTALLABLE` | The skill is a workflow skill; it is materialized by workflow runs, not installed. Use `prowl skills path`. |
| `INSTALL_CONFLICT` | A real file or directory occupies a skill link slot, or a project-scope target folder is a symlink leading outside the repository; nothing was changed. Remove or fix it manually, or choose other targets. |
| `BUNDLE_NOT_FOUND` | The `prowl` binary is not inside a Prowl app bundle and `PROWL_SKILLS_DIR` is unset or invalid — run the installed `prowl` or set the override. |
| `INVALID_SKILL_FRONTMATTER` | A bundled (or `PROWL_SKILLS_DIR`) skill's `SKILL.md` frontmatter is malformed — fix the override skill, or reinstall Prowl if the bundle itself is damaged. |
| `WORKFLOW_INVALID` | `workflow validate` found errors, or `workflow run` named a definition with errors; the full diagnostics are in `.error.details` (JSON) or on stdout (text). Fix the file and re-run. |
| `WORKFLOW_NOT_FOUND` / `WORKFLOW_DISABLED` | No workflow definition with that id or unique name is visible to the worktree, or it is switched off — re-run `workflow list`. |
| `RUN_NOT_FOUND` | No live run with that UUID (`cancel`, manual `deliver`), no record of it in any known worktree (`status`), or the calling pane is not part of an active run (`status` without arguments). |
| `PANE_BUSY` / `DISPATCH_PENDING` (`workflow run`) | The source pane or a `--role` pane already belongs to another active run, or still holds a pending dispatch record that must be completed or abandoned first. |
| `PROFILE_NOT_FOUND` / `PROFILE_NOT_UNIQUE` (`workflow run`) | No enabled Profile satisfies a `launch` role (pass `--role <role>=<profile>`), or the given name matches several. |
| `STEP_NOT_EXPECTING` / `TOKEN_REQUIRED` / `TOKEN_INVALID` | `workflow deliver`: the calling pane holds no waiting activation (the step moved on, was skipped, or the run ended before the output was saved), the completion command was run without its token, or the token belongs to an earlier step. Re-run the latest completion command Prowl typed. |
| `ROLE_MISMATCH` | `workflow deliver --run --step` named a step other than the one the calling pane is waiting for; pass `--force` to deliver there anyway. |
| `OUTPUT_INVALID` / `OUTPUT_TOO_LARGE` / `VERDICT_REQUIRED` | `workflow deliver`: empty body (or, for a `strict` step, missing sections / bad format / bad verdict), body above the step's size cap, or a strict step that declares verdicts got none. Non-strict issues are accepted as `delivery.state = provisional` instead. |
| `WORKFLOW_DELIVERY_REQUIRED` | `agents dispatch-complete` ran in a pane whose pending dispatch is a workflow activation; the message carries the exact `prowl workflow deliver` command to run instead. |
| `REQUEST_CANCELLED` | The CLI disconnected before an in-app workflow request completed; the run itself was not affected. |
| `NO_ACTIVE_PANE` | No pane for focused-target; pass an explicit `--pane`. |
| `EMPTY_INPUT` | `send` got neither argv nor stdin (or both). |
| `INVALID_ARGUMENT` | Bad flag/combo (e.g. `--capture --no-wait`) or out-of-range value. |
| `CAPTURE_UNSUPPORTED` | Target lacks OSC 133 — drop `--capture`, use `read --wait-stable`. |
| `WAIT_TIMEOUT` | `send` did not finish, or `agents wait` saw no matching evidence, before `--timeout`; wait details retain the last observation and signals. Raise `--timeout`, use `--no-wait` (send), or re-arm the wait. |
| `UNSUPPORTED_KEY` / `INVALID_REPEAT` | Check `prowl key --help`. |
| `PATH_NOT_FOUND` / `PATH_NOT_DIRECTORY` / `PATH_NOT_ALLOWED` | Fix the `open`/`create tab` path, or the `skills --scope project` start point (`--path` and the current directory must lie inside a Git repository). |
| `LAUNCH_FAILED` | App launch or socket wait failed; the message includes the last socket diagnostic when available. |
| `TRANSPORT_FAILED` | Socket transport failed for a reason other than app availability or permission, such as `ENOTSOCK` or an invalid `PROWL_CLI_SOCKET` path. |
| `*_FAILED` (`LIST_FAILED`, `AGENTS_FAILED`, `PROFILES_FAILED`, `SKILLS_FAILED`, `FOCUS_FAILED`, `SEND_FAILED`, `READ_FAILED`, `CREATE_FAILED`, `CLOSE_FAILED`, `TAB_FAILED`, `PANE_FAILED`, `OPEN_FAILED`, `HANDOFF_FAILED`, `WORKFLOW_FAILED`) | The action itself failed. |

## Safety & self-targeting

- If your shell runs **inside a Prowl pane**, `$PROWL_PANE_ID` is *you*. Compare
  every target against it so you don't `key enter` into your own session; the
  focused pane is not a reliable stand-in (`open` and `focus` move it).
- Close commands require explicit targets and may prompt for GUI confirmation on
  protected work; `--force` bypasses the prompt.

## A complete loop (run, read, clean up)

```bash
me="$(prowl list --json | jq -c --arg p "$PROWL_PANE_ID" '.data.items[] | select(.pane.id == $p)')"
pane="$(prowl create tab MyApp --json | jq -r '.data.target.pane.id')"
if [ -z "$me" ] || [ "$pane" = "$PROWL_PANE_ID" ]; then
  echo "refusing: self identity is unverified, or \$pane is me" >&2
else
  prowl send --pane "$pane" 'swift build' --capture --timeout 300 --json
  prowl read --pane "$pane" --last 100 --wait-stable --json
  prowl close "$pane" --json
fi
```

## Gotchas for agents (quick list)

- Resolve a UUID `pane.id` or current text `pN` before `read`/`send`/`key`/
  `focus`/close — never trust tab titles.
- You are `$PROWL_PANE_ID`, not "the focused pane"; look up your tab/worktree
  from it when you need them.
- Use `prowl agents --json` for discovery, then `prowl agents read <pN|uuid>` for
  a supported agent's status, blocker, and trustworthy result state; use `prowl list --json`
  when you need all panes, including ordinary shells.
- Use `prowl agents signal` only from the pane reporting the event; it never targets focus
  or another pane, and `turn-ended` never substitutes for a `dispatch-complete` receipt. Check
  `.data.signal.binding`: an `unbound` signal is diagnostics only.
- After launching an agent by hand (`send 'claude'`), wait until `prowl agents --json` lists
  the pane before arming waits or sending prompts: a wait tolerates ten seconds of detector
  latency, and text typed into a runtime that is still starting can merge with the next message.
- `--until idle|blocked` report the current state (a pre-existing signal needs the detector to
  agree); use `--until changed` to wait for the next turn edge.
- To give a running agent another task with a receipt, use `agents dispatch <pane> --prompt -`
  once it is idle — not `send` (no receipt) and not a fresh Profile launch (loses its context).
- `agents read` returns `pending` while the agent works or is blocked, even if a previous turn
  completed.
- `--capture` needs shell integration; otherwise `read --wait-stable` or file
  redirection.
- `open` is navigation, not a guaranteed new pane — use `create tab` or `create pane`.
- In zsh, don't name a variable `status` (it's readonly).
- Pass shell values into `jq` with `--arg`.
