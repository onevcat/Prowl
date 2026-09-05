# Agent Detection

> How Prowl knows there's an agent in a pane and whether it's Working, Blocked,
> Idle, or Done — and which agents it recognizes.

**Keywords:** agent detection, claude, codex, gemini, cursor, working, blocked, idle, done, status, process probe, screen heuristics, indicator, spinner

**Related:** [active-agents](active-agents.md) · [notifications](notifications.md) · [terminal](terminal.md)

## What it is

Prowl continuously inspects each terminal pane to decide whether a coding agent is
running and what state it's in. That signal drives the
[Active Agents panel](active-agents.md), the per-tab activity indicator,
[Canvas](canvas.md) cards lighting up, and [notifications](notifications.md).

## Agents it recognizes

Claude (Claude Code), Codex, Gemini, Cursor, Cline, OpenCode, GitHub Copilot,
Kimi, Droid, Amp, Pi (`pi`), Oh My Pi (`omp`, `oh-my-pi`), Qoder CLI (`qodercli`),
Qwen Code (`qwen`), and Grok Build (`grok`).
Detection covers
common wrappers (node, python, bun, bash, etc.) so agents launched indirectly are
still found. Pi and Oh My Pi are independent detected agents. Pi recognizes its
own minimal working/idle cues, including its built-in braille-prefixed `Working...`
loader and a running `pi-subagents` background card after the parent turn settles;
Oh My Pi owns its richer spinner and interactive
Ask-prompt heuristics, plus its own session layout and icon. Grok Build also
ships an `agent` symlink; Prowl only treats that name as Grok when the path points
at a `~/.grok/` install (so Cursor's own `agent` entrypoint stays Cursor).

## How detection works (two stages)

1. **Process probe.** Prowl reads the pane's foreground process group and matches
   process names / argv against known agent executables, scoring argv[0] highest,
   then process name, then command-line tokens.
2. **Screen heuristics.** Claude detection consumes the full active screen (bounded
   by the terminal height); Pi starts from the last ~32 non-blank lines so an
   expanded background-agent widget stays intact, and every other agent starts
   from the last ~24 as a guard against transcript history. The classifier then selects
   agent-specific live UI regions rather than treating every transcript line as current
   state. Structured confirmation/permission chrome is **Blocked**; status rows and
   spinners are **Working**. Claude working rows come from a live status block walked
   bottom-up from its prompt box by row shape — the spinner or `●` status row, `⎿`
   attachments such as todo lists and tips, queued `❯` messages, and right-aligned
   chrome — stopping at the first transcript-shaped row, so a long todo list cannot
   push the live row out of view and a status row quoted inside a `⏺` block cannot
   read as live. Confirmation text is consulted only around a current numbered
   selection row such as `❯ 1. Yes`; a bare input prompt cuts off the preceding transcript.
   Codex uses exact bottom-of-screen `•`/`◦ Working (... esc to interrupt)` and
   `•`/`◦ Waiting for background terminal (... esc to interrupt)` footer fallbacks.
   Its confirmation detector requires a numbered selected row such as `› 1. Yes`
   paired with a live bottom footer or an explicit Yes/No choice structure. It also recognizes
   the current directory-trust, hook-review, and initial sign-in menus as **Blocked** from
   their complete selected-choice and footer structures. Ordinary prompt text and completed
   responses are not confirmation boundaries.
   Pi also treats its bottom `── <braille spinner> Working ──` footer and the adjacent
   `async subagent … · background` header with a matching braille job row as **Working**.
   The compact `subagents (N/M running)`, progressive
   `Async agents · N agent(s) running`, and multi-job `Async agents · background`
   layouts carry the same signal; completed, paused, and failed cards use static
   glyphs and remain idle. Other agent families keep their own patterns (including
   Oh My Pi's `Working… ⟦esc⟧` loader and bottom-of-screen `󱊷 Working…`
   (also `⎋`/`esc`) prefix form, braille frames, symbol cycles, Cursor's
   hexagons, Kimi's moon phases, etc.). Copilot recognizes the bottom
   `Working … esc interrupt` footer across its `∙ ∘ ○ ◎ ◉` animation frames,
   including an optional streaming-size field such as `· 101 B` or `· 1.2 KB`. Its live boxed numbered choices with
   `enter to select · esc to cancel` are **Blocked**, including folder trust;
   that picker takes precedence over the older `esc to cancel` working cue.
   Claude's live status row (`● <label>… (<elapsed> · …)`) accepts a multi-word
   label and a compound elapsed segment such as `28m 34s` or `1h 4m 2s`, so a turn
   keeps reporting **Working** after it passes a minute.
   For Claude, **background agents** end the main turn while they run, leaving
   `✻ Waiting for 1 background agent to finish` above the input box — a spinner
   glyph with no ellipsis, which the spinner pattern alone rejects. Prowl reads
   that wait row as **Working**, along with the older background-workflow footer
   (`3/5 agents done · 7m 29s · ↓ 288.5k tokens`) below the box.
   The agent switcher block below the box (`⏺ main` plus one `◯` row per agent) is
   deliberately *not* read as activity: a subagent that returns control while it
   still awaits collection keeps its row with the elapsed frozen, so the rows
   cannot distinguish running work from finished work on a single frame.

For diagnostics and sanitized regression captures, `prowl read --source detection`
returns the exact active-screen buffer used by stage 2. It is explicitly requested
because it can differ from the visible viewport when a pane is scrolled; the default
`prowl read` behavior is unchanged.

`prowl agents --json` may also include `detection_reason`, a stable classifier rule or
fallback identifier for the latest screen scan. Codex reports runtime-owned IDs for trust,
hook, sign-in, confirmation, foreground-working, and background-terminal matches. Claude
does the same for viewer,
blocker, spinner, elapsed-status, background-work, and current-composer regions; current
history-search chrome such as `⌕ Filter history…` reports `claude.viewer` and preserves
the last trusted state. An ordinary migrated-profile miss reports
`fallback.noRuleMatched`. Reasons never include screen text, and the text-mode command and
app UI remain unchanged.

Detection tolerates several consecutive process-probe misses before declaring an
agent gone. Screen state itself is deterministic: a recognized Working, Blocked, or
Idle frame takes effect on the next active scan, without a time-based Working hold or
generic screen-motion inference. Viewer overlays (Claude's transcript / history-search
views) are an explicit exception: their chrome covers the live status area, so those
frames keep the last trusted state instead of forcing Idle.

## The state machine

**Raw states:** `working`, `blocked`, `idle`, `unknown`.

**Display states** (what you see):

| Display     | Derived from            | Meaning                               |
| ----------- | ----------------------- | ------------------------------------- |
| **Working** | raw `working`           | actively processing                   |
| **Blocked** | raw `blocked`           | waiting for the user (a prompt)       |
| **Done**    | raw `idle` + **unseen** | just finished; you haven't looked yet |
| **Idle**    | raw `idle` + **seen**   | nothing running                       |

A **Done** pane becomes **Idle** the moment you focus it.

## Cooperative signal bus

Detection remains heuristic UI state. Separately, every live pane now has a terminal-owned
multicast observation stream. A process inside the pane can report explicit runtime events:

```bash
prowl agents signal turn-ended --detail "Review complete"
prowl agents signal needs-input
```

Prowl attributes the socket caller through process ancestry, not focus or
`PROWL_PANE_ID`. A signal can exist for an ordinary shell pane with no detected agent and
does not create or overwrite a detected-agent entry; such a signal is recorded as `unbound`
and never becomes wait or dispatch evidence. `turn-ended` means one interaction ended, not
that an assigned task completed; only a matching `agents dispatch-complete` receipt can
complete an exact dispatch.

Signal eligibility is generation-aware. Prowl binds evidence to the agent's launch process —
the topmost member of the pane's foreground job above the detected process — by PID **and
process start time**, plus its current session only when that attribution is exact or high
confidence. Reading state from a forked engine child (Droid runs its TUI and a `droid exec`
engine as two processes) therefore never counts as a replacement: hooks descend from both, and
only a new launch changes the generation. A dispatch launch accepts its first process generation only when the process
started within ten seconds of launch binding; a later-started process is a replacement even if
the original runtime exited before detection. A medium-confidence session guess remains
diagnostic and never rotates an evidence epoch. Evidence from a reused PID, a replaced session,
a delayed child, or an unverifiable sessionless sender stays diagnostic and cannot advance a
wait.
`prowl agents --json` exposes current-epoch channels
under each existing detected-agent row's `signals`; evidence-only shell panes are not added
to the roster.

`prowl agents wait <pane> --until idle|blocked|changed|exit` consumes the eligible stream and
reports its source and confidence. Exact/high evidence wins; the default `auto` policy may
use a heuristic match only after two seconds of unchanged state. `wait --dispatch` is a
separate exact receipt path and never treats screen state or `turn-ended` as task success.

Each observer receives an atomic current snapshot before live changes. Multiple observers
do not compete with the app's existing single-consumer terminal event stream. Agent removal
keeps the pane stream alive; pane closure emits `surfaceClosed` and finishes it. Bounded
overflow is explicit so future waiters can re-subscribe and resnapshot rather than silently
lose lifecycle or signal evidence.

## Managed native completion signals

Prowl Agent Profile launches of **Claude Code**, **Codex**, **GitHub Copilot**, **Droid**,
**Qoder**, **Pi**, **Oh My Pi**, and **OpenCode** also attach process-scoped native event
bridges without writing user, dedicated-home, or project configuration:

- Claude `SessionStart` verifies launch coverage; `Stop` / `StopFailure` report
  `turn-ended`; `PermissionRequest`, `Elicitation`, and a `Notification` of type
  `permission_prompt` or `elicitation_dialog` report `needs-input`; `SessionEnd` reports
  `session-end`. The `idle_prompt` notification (Claude has sat at an empty composer for
  60 s) is ignored: it means waiting, not needing a person, and accepting it would displace
  the `turn-ended` level that idle waits read and wake `changed` waits on idle panes.
- Codex's native `agent-turn-complete` notifier reports `turn-ended`. Prowl never passes
  Codex's hook-trust bypass flag.
- Copilot, Droid, and Qoder report `SessionStart`, `Stop` (plus Qoder's `StopFailure`), and
  `SessionEnd` the same way. Their `needs-input` comes only from a `Notification` whose type
  is `permission_prompt` or `elicitation_dialog`. Their `PermissionRequest` event is
  deliberately ignored: Copilot and Qoder both emit it while the permission service
  auto-approves a tool and no one is waiting, so it does not mean the agent is blocked. That
  also makes their `needs-input` arrive slightly later than Claude's.
- Pi, Oh My Pi, and OpenCode have no stdin hooks; Prowl ships a small extension for each that
  relays the runtime's own event names through the same bridge. Pi reports `session_start`,
  `agent_settled` (`turn-ended`; `agent_end` fires earlier and is ignored), and
  `session_shutdown`; Pi has no permission system, so it never reports `needs-input`. Oh My
  Pi reports `session_start` and `session_switch` (`/new`) as session starts, `session_stop`
  as `turn-ended` (its `agent_end` fires once per in-process `task` sub-agent and is ignored),
  `tool_approval_requested` as `needs-input` (the built-in approval prompt under
  `--approval-mode always-ask`), and `session_shutdown`. Its in-process `task` sub-agents run
  under their own session ids with their session files nested inside the pane session's
  directory; the extension recognises them by that nesting and forwards only their approval
  prompts, attributed to the pane's session. OpenCode reports `session.idle` as
  `turn-ended` and `permission.asked` / `question.asked` as `needs-input`, only for the
  session the pane is talking to — sub-agent sessions are filtered out by their `parentID`.
  OpenCode announces no session start: its session exists only after the first prompt and
  `/new` / resume emit nothing, so, like Codex, the first `session.idle` verifies the channel
  and an ordinary event with a new session id rotates it.

Each runtime is enabled the way it supports per-launch injection, and none of them changes
what the user already configured: Copilot loads an extra read-only plugin directory shipped
inside Prowl (a user's own `--plugin-dir` and `~/.copilot/hooks/*.json` keep working and are
never merged or rewritten), while Droid and Qoder receive a settings object that merges
Prowl's handlers into whatever settings the Profile already passes. Because Droid accepts
only a settings *path*, its merged copy is written to an owner-only file that is deleted with
the pane. Qoder additionally cannot use flag-supplied hooks at all when `--setting-sources`
is set, so that launch runs unchanged with no exact coverage. Pi (`-e`) and Oh My Pi
(`--hook`) receive the bundled extension file through an additive flag inserted before the
prompt; a user's own extensions and `--no-extensions` keep working. OpenCode receives the
bundled plugin through a launch-scoped `OPENCODE_CONFIG_CONTENT` whose `plugin` list is
appended to whatever content the Profile or the user's shell already exports (config layers
concatenate plugin lists, so global and project plugins are unaffected). `--pure` or
`OPENCODE_PURE` disables every external plugin, so those launches run unchanged with one
warning; under `--auto`, OpenCode auto-replies `permission.asked` in the same millisecond, so
that event is not registered for such launches.

Only an app-issued token plus exact caller-process ancestry and matching pane/runtime/cwd can
produce `hook_claude` / `hook_codex` / `hook_copilot` / `hook_droid` / `hook_qodercli` /
`hook_pi` / `hook_omp` / `hook_opencode` evidence. The channel is not advertised as
`verified_live` until a valid native event completes that end-to-end check. Early Claude
`SessionStart` payloads wait for the first matching process generation instead of being lost.
That first generation may attach after the detector's acquisition window; once attached, a
replacement process, pane close, or launched-agent exit revokes coverage.

Codex exposes only one effective notifier. Before launch, Prowl asks Codex's own bounded
`app-server config/read` protocol for the effective notifier, applies selected-profile and
final CLI-override precedence, and ignores project-layer `notify` exactly as Codex does. An
absent notifier (including a `null` configuration value) is valid and Prowl installs its own
notifier without forwarding. An existing notifier is preserved through an owner-only ephemeral forwarding record and is
`exec`'d with the original payload whether Prowl transport succeeds or fails. If resolution
or record preparation is uncertain, Prowl launches the original argv unchanged, exposes no
exact coverage, and reports one non-blocking launch warning.

Managed hooks apply only to Profile launches. Typing `claude`, `codex`, `copilot`, `droid`,
`qodercli`, `pi`, `omp`, `opencode`, or any other runtime manually keeps the existing
cooperative/transcript/process/screen evidence. A hook
`turn-ended` still does not prove assigned-task completion: dispatch receipts and workflow
completion remain separate protocols.

## How often it runs

- **No polling** for cold panes that have not received recent input.
- ~**2 s** for a short warm window after typing, paste, CLI input, or an initial
  command starts in the pane.
- ~**300 ms** once an agent is detected, so Working/Blocked/Done stays responsive.

The heavier process probe is throttled (cached ≈ 0.75 s per process group unless
something changes) so many panes don't add up to high CPU. Status indicators redraw on a
coarse tick rather than every frame for the same reason.

## The indicator

In tabs and the Active Agents panel, a **Working** agent shows an animated spinner
(the per-agent style detected on screen); **Blocked** is a distinct
attention color; **Idle/Done** are static. The "working" animation style is also
configurable in spirit — Prowl uses a bagua/trigram-style spinner in the agents
list.

## Worktree running indicator

The sidebar worktree row spinner and `prowl list`'s `task.status` report
**running** whenever any pane in the worktree is busy. A pane is busy when:

- a terminal command reports progress (OSC 9;4 / ConEmu-style, e.g. a long shell
  command), **or**
- a detected agent is **Working** or **Blocked** — including Claude waiting on
  **background agents**, detected from the `✻ Waiting for … background agent …`
  row even while the input box looks idle.

A **Blocked** agent is the exception to the spinner. Because it has stopped and
is waiting on you, the sidebar row shows a red attention icon instead of the
spinner — a spinner there would tell you to wait, which is backwards. The row
still counts as **running** for `prowl list`'s `task.status`, so the CLI
contract is unchanged; use `prowl agents` to tell blocked from working. A
worktree that is being created, archived, or deleted keeps its own spinner,
which takes precedence over the agent indicator.

It's a single coarse running/idle bit (it can't distinguish background agents
from a long command). For the agent's finer state use the
[Active Agents panel](active-agents.md) or [`prowl agents`](cli.md). Expect up to
~2 s before it lights on a warm pane; panes with a detected agent rescan about every
300 ms.

## Settings

Agent detection is on by default. Related toggles live in the Active Agents and
Notifications settings (e.g. `autoShowActiveAgentsPanel`,
`showActiveAgentTabTitles`).

## Gotchas for agents

- Detection is **heuristic and best-effort**. A short-lived command between polls
  can be missed; an unusual prompt might read as the wrong state.
- **"Blocked"** is the one that means *a human is needed* — it's typically a
  permission/confirmation prompt the agent is waiting on.
- For deterministic assigned work, use the prompted Profile dispatch receipt and
  `prowl agents wait --dispatch`; generic state waits deliberately retain labelled heuristic
  fallback. `prowl read --wait-stable` remains useful screen evidence, but a stable screen is
  not task completion.
