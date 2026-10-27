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

### Devin CLI

Devin 3000.11.3 uses a `devin` terminal process and a `devin acp` child. Prowl
selects the ACP child for native session ownership and keeps the original terminal
launcher identity. An open `devin/cli/session_locks/<id>.lock` descriptor identifies
the session exactly; leftover lock files and unrelated transcripts are not scanned.

The live composer footer identifies **Working** while thinking, running tools, or
streaming text. Directory trust, permission choices, and selection menus are
**Blocked**. An empty composer after completion or cancellation is **Idle**.
Retained dialog text and old working footers above a new composer are ignored.

Devin currently uses screen state and cooperative delivery, without a managed
`hook_devin` channel or a native state provider. Diagnostic logs and the session
store do not expose a complete live state contract; the native `Stop` hook fires
before other hooks can prevent stopping. A workflow finishes only after its explicit
`prowl workflow deliver` receipt. `agents read` has no semantic Devin result reader;
use `prowl read` for terminal output and workflow delivery for complete artifacts.

### Antigravity CLI

Antigravity (`agy`, verified 1.3.2) keeps an attached conversation's
`~/.gemini/antigravity-cli/presence/<id>.lock` descriptor open for the life of
the session, so that open file — not a lock file left behind after exit —
identifies the session exactly. Its `conversations/<id>.db` and
`brain/<id>/.system_generated/logs/transcript.jsonl` share the same id.

The detector reads the full active screen and anchors on the live composer:
a terminal-wide `─` border, a column-0 `>` prompt row (wrapped input
continues on indented rows), and a terminal-wide `─` bottom border. The
built-in status row renders directly below that box — `esc to cancel` or
`esc to interrupt` is **Working** while a turn runs, `? for shortcuts` is
**Idle** — padded away from the right-aligned model label (`Gemini 3.8 Flash
· high`, `Claude Sonnet 4.6 (Thinking)`, or nothing until the label
resolves). The last composer on screen is the live one, and the row under
its bottom border is the only state evidence: a `stack_with_default` status
script renders verbatim below that row, so nothing below it counts, however
it is shaped. A typed draft drops the signature from the status row (only
the model label remains), and the slash-command autocomplete popup that
opens under the composer when `/` is typed rewrites it to `esc to cancel`
whatever the turn state; both are **unknown**, so the state from before the
user started typing is retained. A screen without a composer, a composer
caught without its status row, or a viewer such as `/help` or `/model` is
**unknown**, never Idle.

Workspace-trust, tool-permission, and ask-user dialogs are **Blocked**: they
replace the composer with option rows (a column-0 `> ` marks the selection,
within eight rows above the hint) and a `↑/↓ Navigate` hint row, and a
permission dialog keeps `esc to cancel`, so the dialog read runs before the
status row and nothing below the hint can veto it. The autocomplete popup
shares the hint shape but renders below a live composer box, which a dialog
never does, so a hint under a composer is the popup. Agent responses render
indented, so column-0 dialog chrome is the live dialog or the user's own
echoed text; a verbatim quote at column 0 reads Blocked until it scrolls off
the screen, a delay rather than a dispatch into a modal prompt. Answered
dialogs leave only the chosen option echoed at column 0 (`> Red`), never the
hint. A bare hint row with no selection — cropped
chrome or residue — denies the composer evidence below it and reads
**unknown**. Option shape alone is not dialog evidence: a slash command
echoes as a column-0 `> ` row with no rule above it and an indented result
beneath, and an echoed prompt whose rule scrolled off the top of the screen
looks the same, so a dialog whose hint copy the detector does not recognize
falls through to the composer read and fails toward unknown, never Idle.

Terminal width is the longest `─`-only column-0 row on screen. The echoed
prompt's rule is narrower, agent responses render indented, and the dialog
rule is not followed by a prompt row, so none of them can pose as the
composer. The accepted residual is a user's own status script that draws a
terminal-wide `─`/`>`/`─` box followed by a padded status signature under
an idle or working composer; that output is the user's configuration, and
the plain spoofs reviewed so far (`? for shortcuts custom help`, narrower
boxes, dividers) fail toward unknown, while a live dialog stays Blocked
whatever is stacked beneath it.

A pane that never shows a recognized screen — a headless `agy --print` run,
a viewer overlay such as `/diff`, or a future layout change — reports
unknown the whole time. Its process is still classified, but an unknown
pane emits no roster entry: it is absent from Active Agents and
`prowl agents`, `agents wait --until idle|blocked` times out on it, and
`agents wait --until exit` treats it as gone. The state machine retains the
last recognized state, so a working turn that only briefly drops its footer
stays Working.

Antigravity currently uses screen state and cooperative delivery, without a
managed hook channel or transcript reader.

### TraeCode CLI

TraeCode CLI (`traecli`, verified 0.201.7) is a Codex-CLI fork: it reuses Codex's
session-store shape under `~/.trae/cli/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`,
held open for the life of an interactive session, so the open rollout file
identifies the session exactly. `TRAE_HOME` relocates the whole `~/.trae` tree
(verified: an isolated run wrote its config and sessions under the relocated
`cli/sessions`), so a managed Agent Profile binds the account through `TRAE_HOME`.

The detector reads the whole active screen — not a bottom tail — and resolves the live
region by position: the composer box (a column-0 `❯` prompt row whose wrapped input
continues on indented rows, the `─` separator that draft run ends on, and the status row
directly below it) and a live dialog are both searched, and the lower of the two
decides. The box is delimited by its own rows, never by a width measured against the
rest of the screen: the pane's text is read non-rectangularly and soft-wrapped lines are
joined, so a historical *logical* line — the agent's own output leaving a rule behind —
can be wider than the live border, and sizing that border by the longest rule on screen
lost the whole box (an idle `❯ Draft` read unknown instead of idle, and a numbered draft
fell through to the dialog shapes as if it were approval options). The
transcript quotes both shapes, so a quoted composer above current approval options must
not hide the dialog, and a quoted dialog above the live composer must not read as
Blocked. Everything inside the box is the user's draft, so a quoted transcript above it
— even a verbatim dialog — is not evidence while the box is the active region. The live
block above the box is read as a single blank-bounded run with no row cap, so a tall
todo checklist cannot push the running hint out of view: an `esc to interrupt`-style
hint in that run is **Working**, except traecli's startup MCP boot progress line
(`Starting MCP servers (n/m): … esc to interrupt`), which reuses that footer but is
startup work, not a turn. That exclusion is applied to the whole block, not to one row:
the progress line is logical, so a terminal that wraps it puts the footer on a
continuation row with none of the header. (Captured on 0.209.1 in a 40-column PTY,
traecli *clips* that line instead — the server list ends in `…` and the hint is cut
with it — so the wrapped form is a defensive case rather than one observed today.) With
no such hint, the composer's own status row — `<model> · Context <n>% left · <cwd> ▧
Workspace Edit` — is **Idle**, and an unrecognized status row under a live composer is
also **Idle** rather than unknown, so a running turn's Working never lingers. That
status row is identical in both states, which leaves the running footer as the only
mark that separates them, and traecli repaints the live region on its own clock
(0.209.1 draws as slowly as once a second while a turn streams). A lone **Idle** frame
over a **Working** pane is therefore held instead of published, and only settles the
turn once the Idle verdict has kept arriving for
`AgentStateMachine.confirmedIdleWindow` (2 s, above the ~1 s gap traecli was observed to
drop its footer for): the frame can be a repaint gap, and reading it flipped the pane
Working → Idle → Working (and earned a spurious Done badge on an unviewed pane). The
window is measured in time, not in observations, because a repaint gap yields several
Idle frames at the poll cadence and repeated reads of one frame — `prowl agents read`
polls the pane outside the detection cadence — arrive back to back. A Working or
Blocked frame drops the hold, and an unreadable frame neither confirms nor cancels it.
Idle → Working, Working → Blocked, and settling from unknown stay immediate, so a
starting turn and a dialog are never delayed.

traecli clips that footer to the pane width before it reaches the terminal, so a wide
live-block header arrives with its tail cut off: `✦ <streaming snippet> (42m 53s • ↑
183K tokens …` keeps neither `esc to interrupt` nor the `/ps` chrome, and the running
turn then reads as a settled composer (captured live on 0.209.1 at the moment the
badge flipped). Two guards cover that frame. The detector treats a clipped header as
the running hint: a column-0 live glyph (the rotating sparkle marks, `✦ ✧ ❖ ◆ ◈ ⋄ …`)
followed by the elapsed-time chrome `(<elapsed> •` — in a narrow pane the clip can
fall right after the bullet (`✦ Working… (2s •…`). Prose, tool output, and quoted
chrome cannot forge it — `└ Run finished (2s · timeout 2m)` is indented and uses `·`,
not `•` — so a transcript line only qualifies when it opens with that glyph. Clipping
can cut even the elapsed opener off, and a pane scrolled into history or caught mid
repaint can drop the live block entirely, so an **Idle** screen verdict is also
corroborated against the pane's terminal title: traecli animates a braille spinner
ahead of the thread title while a turn runs (`⠋ Fix iOS H5 input keyboard issue`)
and drops it when the turn settles — a background shell left running does not keep it
up — so a spinning title turns an Idle screen verdict into Working, reported as
`screen.titleSpinner`. The TUI writes that mark itself, so unlike the composer it
survives clipping, scrolling, and slow repaints. Working, Blocked, and unknown
verdicts pass through unchanged: the corroboration only prevents a false Idle (and the
spurious Done it earns on an unviewed pane).

traecli 0.209.1 can also hold **background shells** (`/ps to manage`). While one runs,
a *settled* turn's footer becomes `◇ <n> background shell running… you can still chat ·
/ps to manage` — the interrupt hint and the elapsed counter are both gone — so the pane
reads **Idle** with work still in flight, and it returns to Working only when the agent
starts the turn that collects the shell. That is deliberate, not a miss: the agent has
handed control back, only the shell is running, and a running background shell is
therefore not Working evidence. A turn that is *still* streaming keeps its hint and
appends the same segment (`… esc to interrupt) · 1 shell running… · /ps to manage`).

A live dialog that replaces the composer is **Blocked**. Four shapes are matched by
shape, not column: a numbered option row marked with `❯` beside an unselected sibling;
a form whose only chrome is its submit/navigate footer; a bracketed y/n confirmation
(`… [y/N]`); and the interactive login/auth screens (a verified header phrase plus its
Enter/Esc chrome). Most dialogs render inside the live block's two-space gutter, but
the first-run trust prompt and the login screens render their question and choices at
column 0, so the region is delimited by what it *stops* at instead of by indentation:
the composer box (its prompt row, its `─` rules, the status bar under it),
the live block's or transcript's own glyph-headed rows, and the welcome banner that the
trust prompt renders under, capped at 16 rows so a
transcript running straight into a dialog cannot hand `agents read` unbounded history.
A dialog that renders *below* a composer box supersedes it — the box is then quoted
transcript — while a dialog above the live composer stays transcript. Anything else is
**unknown**, never Idle, so a screen without the live composer cannot forge an idle
reading.

The chrome is matched by its structure, not by a phrase inside it. A footer row has to
carry its cancel/navigate chrome as well as the submit or navigate phrase
(`enter to submit | esc to cancel`, `↑/↓ to navigate fields   esc to cancel` on the
on-prem build; key hints such as `enter confirm  |  esc cancel` on the public 0.209.1
build, which need both an `enter` and an `esc` segment), the
running interrupt mark has to be parenthesized (`(esc to interrupt)`,
`(23s • esc to interrupt)`), and the auth chrome has to open with its key chord
(`Press Esc to cancel`). The composer's status bar — `<model> · Context <n>% left ·
<cwd> ▧ Workspace Edit` — is dynamic chrome and never counts as dialog, footer, or
running chrome, because it carries the working directory: without both rules a
checkout at `/tmp/how to submit` read as a form footer and turned a settled composer
into Blocked, and `/tmp/how to interrupt` turned it into Working.

A typed screen profile is still deferred — the working signature is the binary-verified
`to interrupt` hint — but `prowl agents read` extracts the live dialog text as its
blocker for a TraeCode CLI pane. The extraction reads the same region the detector
resolved, so the two cannot disagree about where the dialog starts, and it keeps the
whole dialog, from the question through the tool's command or parameters to the option
rows and their footer, spanning the blank lines traecli renders inside it: a caller has
to be able to see what it would be approving.

TraeCode CLI currently uses screen state and cooperative delivery, without a
managed hook channel or transcript reader. Its TUI notification is off by
default, so a Prowl-launched session has `tui.notifications=true`,
`tui.notification_method=osc9`, and `tui.notification_condition=always` injected
as `-c` overrides; otherwise a finished turn never reaches the notification
inbox (see [notifications](notifications.md)). A manually launched `traecli`
needs the same values under `[tui]` in `~/.trae/traecli.toml`.

## Agents it recognizes

Claude (Claude Code), Codex, Gemini, Cursor, Cline, OpenCode, GitHub Copilot,
Kimi, Droid, Amp, Pi (`pi`), Oh My Pi (`omp`, `oh-my-pi`), Qoder CLI (`qodercli`),
Qwen Code (`qwen`), Grok Build (`grok`), Devin (`devin`), Antigravity
(`agy`), and TraeCode CLI (`traecli`). Detection covers
common wrappers (node, python, bun, bash, etc.) so agents launched indirectly are
still found. Pi and Oh My Pi are independent detected agents. Pi recognizes its
own minimal working/idle cues, including its built-in braille-prefixed `Working...`
loader and a running `pi-subagents` background card after the parent turn settles;
Oh My Pi owns its richer spinner and interactive
Ask-prompt heuristics, plus its own session layout and icon. Grok Build also
ships an `agent` symlink; Prowl only treats that name as Grok when the path points
at a `~/.grok/` install (so Cursor's own `agent` entrypoint stays Cursor).

## How detection works

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
   Claude's internal scroll view keeps the composer visible while hiding live status.
   When `Jump to bottom (click) ↓` or a counted `new message(s) (click) ↓` control appears
   in the last non-blank row above that composer, Prowl treats the screen as a viewer
   and retains the last known state. The control can overlay text in the middle of a row.
   Return to the bottom to refresh
   screen-based status; completion while browsing history is not visible to this detector.
   Codex uses exact bottom-of-screen `•`/`◦ Working (... esc to interrupt)` and
   `•`/`◦ Waiting for background terminal (... esc to interrupt)` footer fallbacks.
   The footer can also sit up to three text rows above the composer, so `└` detail rows
   such as a background command or a `Tip:` between them do not hide it.
   Braille-only starfield rows around the composer do not count toward that footer window;
   animation alone does not indicate **Working**.
   An empty Codex composer hint and status line remain **Idle** evidence with Astra's
   starfield background, so a workflow can send its first task before any turn has completed.
   The shortcut hint row that Codex 0.158 shows below the status line
   (`← for agents · ? for shortcuts`) does not change this.
   Draft text and attachments do not qualify as an empty composer.
   Its confirmation detector requires a numbered selected row such as `› 1. Yes`
   paired with a live bottom footer or an explicit Yes/No choice structure. It also recognizes
   the directory-trust (including Codex 0.158's `Trust this folder?` prompt), hook-review,
   and initial sign-in menus as **Blocked** from
   their complete selected-choice and footer structures. Ordinary prompt text and completed
   responses are not confirmation boundaries.
   Amp (verified 0.0.1791547250) reads only its bottom composer box. Any status in the
   box's bottom border — `Connecting`, `Sending`, `Waiting`, `Thinking`, `Streaming`
   (with or without a token counter), `Running Tools`, and whatever else the thread
   client reports behind its `∼`/`≈`/`≋` spinner — is **Working**; a bare border is
   **Idle**. `Disconnected` and `Amp Is Redeploying` keep the previous state. A dialog
   box directly above the composer (`Approval Required` with `‣`-marked options,
   `Tell Amp what to do differently`) is **Blocked** even though the border still says
   `Running Tools`, and so is a `‣` option row inside the composer (`Out of Credits`).
   Quoted status or approval text elsewhere on screen is ignored, and a screen without
   a complete composer keeps the previous state. Older Amp builds cannot start threads
   any more, so their `esc to cancel` and approval-text cues are no longer recognized.
   Pi also treats its bottom `── <braille spinner> Working ──` footer and the adjacent
   `async subagent … · background` header with a matching braille job row as **Working**.
   The compact `subagents (N/M running)`, progressive
   `Async agents · N agent(s) running`, and multi-job `Async agents · background`
   layouts carry the same signal; completed, paused, and failed cards use static
   glyphs and remain idle. Pi 1.1.0 and later also reports its state through
   [program status](#program-status-osc-7501), and that root record outranks these
   screen cues: the footer and the subagent cards are read only when Pi sends no
   reports (`PI_PROGRAM_STATUS=0`, older versions). Pi's built-in tools never ask for
   confirmation, so its first **Blocked** comes from the protocol: an extension dialog
   (`ctx.ui.confirm` → `osc.blocked.permission`; `select`, `input`, `editor` →
   `osc.blocked.question`) or an OAuth login wait (`osc.blocked.auth`); a provider
   failure during a turn is `osc.error`, which reads as Idle and may show the Done
   badge. Pi's own selectors (`/model`, `/settings`) send nothing and leave the
   previous state in place.
   Oh My Pi's loader row is **Working** evidence when it leads with the theme's Esc
   glyph (`󱊷`, `⎋`, or `esc`) followed by any label: the label is the model's own
   intent (`Working…`, `Running requested command`, `等待命令完成`, …) and is not
   enumerated. The row counts in the bottom five non-blank rows and in the five rows
   directly above the live `box` composer, so a long queued draft does not hide it.
   While a turn runs, Oh My Pi's status line swaps its brand glyph for a braille spinner
   and turn timer (`⠋ 9s`); the `box` composer embeds that status in its `╭──` header,
   which is **Working** evidence when the header belongs to the live composer — the last
   `╭` row followed only by `│` input rows and a final `╰` row, which covers one-line,
   multiline, and IME-safe layouts. An older spinner frame above transcript text or above
   a newer idle composer is ignored. The `band` (fresh-install default), `claude`, and the
   other composer shapes start a status row with that spinner, which the leading-spinner
   rule reads; an idle composer shows the static brand glyph instead.
   Oh My Pi 18.8.7 and later also reports its state through
   [program status](#program-status-osc-7501), and that root record outranks its screen
   cues, which are read only when Oh My Pi sends no reports (`terminal.programStatus:
   false`, older versions). A tool approval prompt is `osc.blocked.permission`, an `ask`
   question is `osc.blocked.question`, and a failed turn is `osc.error`. A background
   (`async`) bash job keeps the root `working` until the job's result turn ends, so the
   pane stays **Working** meanwhile.
   Other agent families keep their own patterns (including
   Oh My Pi's `Working… ⟦esc⟧` loader and the Esc-prefixed loader row above,
   braille frames, symbol cycles, Cursor's
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

3. **State decision.** Every agent uses one state machine. Codex also supplies
   incremental JSONL lifecycle evidence from process-owned session logs, without
   installing hooks. Claude supplies process-scoped native state without hooks.
   These providers and the screen rules apply when no verified OSC root is present.
   For Codex without OSC authority, an observed open
   parent turn or child task stays **Working** through quiet periods; current
   approval/question UI takes precedence as **Blocked**. Completion closes only
   its matching work. Initial historical records do not start new work.

   Multiple main sessions fall back to screen heuristics unless only one has open
   work or main-turn activity within the last two minutes. Known subagents are
   grouped with their parent. Child notifications and file mtimes do not refresh
   main activity. Missing/unreadable logs or unknown lineage also fall back to the
   screen. Attribution is heuristic: switching to an old quiet chat before entering
   a new prompt can temporarily retain the previous log candidate.

   A `codex` typed by hand in Codex 0.157+ attaches to a shared background daemon
   that owns every session log, so the TUI process holds none. Prowl then reads the
   daemon's logs for the thread this pane's Codex last submitted to, identified
   through the pane's Codex session log (see
   [cli identity](cli.md#identity-which-pane-am-i)), plus that thread's subagents.
   Until the pane's Codex submits its first message, and for a moment after each
   new submit, detection falls back to the screen. A Codex launched from an Agent
   Profile or with `--no-daemon` owns its logs and is read directly.
   If a previously established daemon binding becomes unavailable, detection falls
   back to the screen but retains its log cursors. When the binding returns, it
   consumes pending events without replaying earlier turn starts.

   Codex 0.163.0 and later sends [program status](#program-status-osc-7501)
   with `app=codex`. Its root outranks the log provider and screen rules; the log
   provider is not sampled while it decides. Session identity and semantic results
   still use the session resolver and transcript reader. Codex sends `idle` after
   completion or cancellation, so OSC alone does not earn a Done badge or prove a
   dispatch completed. Approval and question prompts report `blocked` without a
   kind (`osc.blocked.unspecified`). Codex clears its record when it hands the
   terminal to an external program or exits, and re-emits after returning. It has
   no OSC-specific opt-out; older versions remain on the existing fallback path.

   Claude reads the detected PID's native registry under its configured root
   (`~/.claude/sessions` by default). `busy` means **Working**, including assigned
   child work; `waiting` means **Blocked**; `idle` means **Idle**, and so does `shell`,
   where the turn has ended and the composer accepts input while background shells
   still run. Process generation is checked before and after each read.
   `/new` and resume use the registry's current session. Two processes sharing a
   transcript retain independent states. Missing, partial, stale, or unsupported
   records fall back to the screen. The registry's `sessionId` is also the pane's
   session identity (`process_log`, `exact`): it follows `/clear` and an in-process
   `/resume` without any screen text, within the resolver's 5 s result cache plus one
   delegated tick (about 7 s) while the registry stays readable, so a delegated pane
   tracks a rotation too. A transient read failure keeps the last registry identity
   for three poll resolutions before the transcript scan and fingerprint take over
   (`agents read` reports only current evidence meanwhile); they remain the fallback
   for versions without the registry. Background daemon/remote sessions are not
   supported by this adapter. A manually relocated config root must be supplied
   through a Prowl launch profile; shell-only overrides can fall back to screen.
   Claude Code 2.1.295 and later also reports its state through
   [program status](#program-status-osc-7501). That root record outranks the
   registry and the screen, and the native state provider does not sample the
   registry while it decides (the session resolver still reads it for identity). The
   registry and the screen rules are the fallback: Claude sends nothing before the
   trust dialog is answered, so that prompt is still the screen blocker, and a
   cleared record hands the pane back to them. A finished command (OSC 133) only
   wakes a fresh probe: the same Claude keeps its record and its authority (a
   nested shell's prompt), and a confirmed exit releases the entry.

For diagnostics and sanitized regression captures, `prowl read --source detection`
returns the exact active-screen buffer used by stage 2. It is explicitly requested
because it can differ from the visible viewport when a pane is scrolled; the default
`prowl read` behavior is unchanged.

`prowl agents --json` and `prowl agents read --json` use `detection_reason` for
the final state decision and `screen_reason` for the screen rule. Codex can report
`log.openWork`, `log.turnEnded`, or a `screen.*` fallback reason; `raw_state` remains
the latest screen classification. A current blocker reports its screen-rule ID.
Claude reports an `osc.*` reason while its program status root record decides, and
otherwise `native.working`, `native.blocked`, or `native.idle`; a fresh screen
blocker can retain its screen-rule ID. Screen-only runtimes keep their existing rule identifiers. An ordinary profile miss
reports `fallback.noRuleMatched`; unmigrated classifiers report `legacy.detector`,
which is also Pi's fallback reason when no root record decides.
Reasons never include screen text. Screen fallback IDs are:

- `screen.logUnavailable`: log authority is unavailable or suspended.
- `screen.ambiguousLogs`: more than one log root is recently active or has open work.
- `screen.noLiveTurn`: no root has current log authority.
- `screen.afterTurn`: new Working screen evidence appeared after completion.
- `screen.retainedCompletion`: an unchanged completed frame is still suppressed.

For idle waits and dispatch readiness, a current `log.turnEnded`, `native.idle`, or OSC
`osc.idle`/`osc.done`/`osc.error` decision keeps
the existing idle evidence and stabilization rules even when the screen reports
`fallback.noRuleMatched`. Without current log authority, that unmatched screen
provides no idle evidence. Dispatch still checks the input area before delivery.
Readiness reads the detector's current decision, not the Active Agents entry: a
reason that moved from `screen.*` to `osc.idle` without a state change never reaches
the entry, and a withdrawn OSC reason is dropped from the current decision at once.

## Program status (OSC 7501)

Programs that speak the [program status protocol](https://www.superlogical.com/rex/docs/build/program-status)
report their own state into the terminal: `idle`, `working`, `done`, `blocked` (with a
`kind` of `permission`, `question`, or `auth`), `error`, and `clear`, optionally per
record id (`build/test` is a child of `build`). Prowl answers the support query and keeps
one record tree per pane with the protocol's rules: a report replaces its record, `clear`
removes a record and its descendants (an empty id removes everything), a record without
`app` inherits the nearest ancestor's, and at most 256 records are kept. Record text
(`title`, `msg`) is never logged or published.

A root record is **attributed** to the pane's detected agent only when its `app` is the
agent's own name (`claude-code` for Claude Code, `pi` for Pi, `omp` for Oh My Pi, `codex` for Codex) and it arrived after that
agent's process started. That rejects another program's records and a predecessor's
leftovers (an agent that exited without `clear`); it does not authenticate the writer: a
wrapper or nested program that writes the expected `app` is attributed like the agent
itself. Whether an attributed root may **decide** the state is a static per-agent table
in the app, not a setting:

| Support | Meaning |
| --- | --- |
| unverified | Records are stored and resolved, but only compared with the live decision; disagreements are logged (`AgentDetection` category). Every agent except Claude Code, Pi, Oh My Pi, and Codex today. |
| verified | The root record is the first-priority state evidence, applied the moment the report arrives. Claude Code (2.1.295 and later, `app=claude-code`), Pi (1.1.0 and later, `app=pi`), Oh My Pi (18.8.7 and later, `app=omp`), and Codex (0.163.0 and later, `app=codex`). |

For a verified producer the pane follows the **root** record only: `working` → Working
(`osc.working`), `blocked` → Blocked (`osc.blocked.<kind>`, `unspecified` without a
kind), `idle`/`done`/`error` → Idle (`osc.idle`, `osc.done`, `osc.error`). A child
record that is `blocked` makes the pane Blocked (`osc.childBlocked.<kind>`) and vetoes
idle waits, because a subagent's prompt needs an answer; a child that is `working`
changes nothing, so background agents and subagents never keep a pane Working or block
`agents wait --until idle`, dispatch, or workflows. `done` and `error` may show the Done
badge; `idle` never does (it is sent at mount, on interrupt, and on a session reset).
While the root record decides, Prowl stops reading the screen and the native/log files;
every 2 s it only probes the process and resolves the session (against the last screen
text it read), and `screen_reason` reports `screen.delegated`. A key press or CLI input
puts the pane back on the 300 ms loop, with screen reads, for about 3 s, so a session the
input switched (`/new`, `/resume`) is attributed from the frame it settles into before the
tick delegates again. Clearing the record withdraws that authority and the next poll reads
the screen and the native/log files again, with their usual reasons; a finished command
wakes the probe described below, which keeps the authority when the same agent is still
there and releases the entry when it is gone. There is no silence timeout.

Producers that never report (older versions, `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`,
`PI_PROGRAM_STATUS=0`, Oh My Pi's `terminal.programStatus: false`) get today's screen and provider detection unchanged. The
available producer controls are the escape hatch; Codex 0.163.0 has none for OSC.
Prowl has no setting for this.

Independently of the support table, Ghostty's shell integration tells Prowl when the
foreground command finished (OSC 133). Detection then probes the process at once,
bypassing its cache, and a single miss releases the pane's agent entry instead of the
usual six consecutive misses, so a normal exit or a `kill -9` of any agent clears Active
Agents within about a hundred milliseconds. Panes without shell integration (nested
shells, `--shell-integration=none`, ssh, tmux) keep the slower six-miss release. A
finished nested shell inside a running agent releases nothing: the probe still finds the
agent. Oh My Pi writes its own OSC 133 marks around each user message it draws, which
uses up the shell's command timer: once it has drawn one (a turn, or a resumed session's
history) its exit takes the six-miss release (2–3.5 s), and a `prowl send` waiting for the
`omp` command returns as soon as Oh My Pi draws its first user message.

Use `status` to decide whether intervention is needed. A blocked `screen_reason`
with Idle status can be a stale prompt fenced by completion; do not send Enter
based on the screen reason alone.

Native acquisition warnings report a bounded failure category and recovery, without
registry content. They use the same per-category 30-second throttle.

Log acquisition warnings use the `AgentDetection` category. `ProwlLogger` writes
them to stdout in Debug and the unified log in Release. They identify the PID, cursor count, and failure category (`incompleteInventory`,
`partialHeader`, `unknownLineage`, or `continuityLost`). Warnings are limited to one per failure category per provider every 30 seconds;
a successful read reports recovery once after any failure, including a throttled one.
Continuity-loss warnings report the post-reset cursor count and a bounded error kind/code. These logs contain no transcript or screen content.

Detection tolerates several consecutive process-probe misses before declaring an
agent gone. Screen-only state is deterministic: a recognized Working or Blocked frame
takes effect on the next active scan, without a time-based Working hold or generic
screen-motion inference. One exception covers agents whose Working evidence is
screen-only (`DetectedAgent.requiresConfirmedIdleScreen`, currently `trae`): an Idle
frame over a Working pane is applied only once Idle has kept arriving for
`AgentStateMachine.confirmedIdleWindow`, so neither a single mid-repaint frame nor a
burst of them can end a turn; the TraeCode CLI section above adds the clipped-header
and title-spinner corroboration. Viewer overlays (Claude's transcript /
history-search views) are another exception: their chrome covers the live status area,
so those frames keep the last trusted state instead of forcing Idle.

## Remote agents over SSH

When a pane's foreground command is a local `ssh`, Prowl shows the agent that runs on the
host (docs-ai 082, L0). Prowl installs nothing on the host and edits no rc file. SSH processes
started by Git, scp, sftp, or rsync are transports, not remote agent sessions: they do not
show a consent prompt or start detection. Direct commands such as `ssh -t host claude` and
`ssh host tmux attach` still qualify.

- **Consent.** Prowl does not connect to a host before you agree. The first `ssh` that
  Prowl can read shows "Detect agents on <host>?" in the toolbar status, with its panel
  open. The panel does not take keyboard focus, so you can finish a password or code
  prompt first. **Turn On** starts detection in the open `ssh` panes at once, **Not Now**
  asks again after Prowl restarts, and **Turn Off** stops asking. Until you choose, Prowl
  opens no connection. Settings › Agents › Display › **Detect agents in SSH sessions**
  holds the answer; the switch shows on until you turn it off. The environment variable
  `PROWL_REMOTE_AGENT_DETECTION` overrides the setting and never asks: `0` turns the
  feature off, any other value turns it on.
- **Remote projects.** A tab that Prowl opens for a remote project runs `ssh` itself. It asks
  for no consent, because adding the folder already agreed to the connection, and it uses
  the folder's stored SSH settings instead of reading the command line. Its pane and agents
  show the host's alias. `PROWL_REMOTE_AGENT_DETECTION=0` still turns detection off. Once
  that `ssh` ends, a later `ssh` in the same pane is your own and follows the rules above.
- **Directory.** A remote agent's directory (its project in Active Agents and `prowl
  agents`) is the one the probe reads on the host, not the pane's local directory.
- **Toolbar status.** While the focused pane's `ssh` uses Prowl's own connection, the
  toolbar status shows the host and "Agent detection on", or "Agents not detected" with a
  warning glyph. Hover (or click) for a panel that tells what the extra connection does,
  why agents are not detected, and a button to the setting. The consent question ranks
  above workflow runs there; this status ranks below workflow runs and rate limits, and
  above the pull request.

- **How.** Prowl opens its own SSH connection to the same target (`ssh -G` resolves user,
  host name, port, `ProxyJump` and `-F`). It runs a read-only probe over that connection:
  about once a second while a remote agent is listed, and every few seconds otherwise.
  The probe finds the pane's session by `LC_PROWL_PANE`, which the default OpenSSH
  `SendEnv`/`AcceptEnv` settings forward, and reads the session's foreground process. A
  verified producer's OSC 7501 reports decide the state, as they do locally; otherwise the
  screen decides.
- **Pane and tab.** A pane whose foreground `ssh` reaches a host shows `user@host` in its
  bottom-trailing corner, and its tab shows a network glyph before the title (the tooltip
  names the hosts). Five seconds after the label appears or changes, only its glyph stays;
  the pointer on the glyph shows the host again. When that `ssh` exits and the pane is back in its local shell, the
  corner reads "Disconnected from user@host" for five seconds. A suspended `ssh` (still
  running) only removes the label. When Prowl cannot read the pane's agents (the host has
  no session for the pane, the side channel fails, or the `ssh` command is not supported),
  the label shows a yellow warning glyph instead, whether or not an agent is listed. Its
  tooltip gives the reason, and says that only agents that report their own status
  (OSC 7501) are detected.
- **Host label and health.** The Active Agents row shows `user@host` with a network
  glyph. Connection health is shown apart from the agent's state. If no snapshot has
  confirmed the agent for 10 s, the row keeps the last state, greys it out, and adds
  "Last seen … ago". "Status unavailable" means the host was never read. A **Blocked**
  state stays red: OSC has no heartbeat, so a blocked agent goes quiet while it waits
  for you. A state of
  "Unknown" means the host confirms the agent but no evidence decides its state. The tooltip names
  the reason (for example, an unknown host key, or a server that does not accept
  `LC_PROWL_PANE`).
- **Degraded binding.** Sometimes the host cannot be read, or has no session for the pane:
  `-F` without `SendEnv`, a refused key, or an `ssh` command outside the supported grammar.
  In that case a verified producer's OSC 7501 report still lists the agent, with
  `heuristic` confidence. Only the `ssh` exit releases such an agent. When its producer is
  quiet for 10 s, it becomes stale.
- **Inside tmux.** When the remote session's foreground is a tmux client, Prowl maps that
  client to its active pane through the tmux server (never through inherited environment
  variables). It identifies the agent from that pane's foreground job, and reads the
  agent's state from the pane's visible screen (`tmux capture-pane`), not from the local
  screen. The local screen also shows the tmux status line, other panes, and copy mode.
  tmux drops OSC 7501, so screen rules decide the state there. Copy mode does not change
  the state. Switching to another pane releases the agent, and switching back shows it
  again within a few seconds. A second client attached to the same pane shows the same
  agent in its own Prowl pane. A changing local screen asks for a fresh capture, with at
  most one probe in flight. A screen larger than 64 KiB keeps its last lines. When many
  panes are captured at once, the screens of Prowl panes come first, and a screen past
  the probe's budget leaves that agent's state unknown for that probe.
- **tmux limits.** Prowl looks for tmux servers only in `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/`.
  When it cannot reach the server of a client (for example a server started with
  `tmux -S <path>`, or a removed socket), the pane badge shows a warning and
  `remote.correlation` is `tmux_unreachable`. An agent that was already listed stays
  listed, and its state becomes unknown after 10 s; it is not released. Prowl follows
  one level of tmux only: a tmux inside a tmux pane, or a program in a `display-popup`,
  is not read.
- **Release.** A probed agent is released after two complete fresh snapshots without it
  (about 2–3 s after it exits), or at once when the `ssh` exits.
- **Limits.** A remote agent cannot be a `prowl agents dispatch` target that needs a
  receipt, or a workflow `current`/`pick` participant: both fail with
  `REMOTE_AGENT_UNSUPPORTED`. A stale or state-unknown observation never satisfies an
  `idle` or `blocked` wait, or input readiness, until the host confirms the agent again. Local session files,
  transcripts and hooks are never read for a remote agent.

## The state machine

**Raw states:** `working`, `blocked`, `idle`, `unknown`.

**Display states** (what you see):

| Display     | Derived from            | Meaning                               |
| ----------- | ----------------------- | ------------------------------------- |
| **Working** | raw `working`           | actively processing                   |
| **Blocked** | raw `blocked`           | waiting for the user (a prompt)       |
| **Done**    | raw `idle` + **unseen** | just finished; you haven't looked yet |
| **Idle**    | raw `idle` + **seen**   | nothing running                       |

A **Done** pane becomes **Idle** when it is actually viewed: its worktree and tab are selected,
its pane is focused, and the Prowl window is key and visible. Keeping a pane selected while
Prowl is inactive, hidden, or minimized does not mark its completion as read. Unknown window
state is conservatively treated as not viewed. An acknowledged completion stays read when
a pending session lookup finishes; a later unviewed completion still becomes **Done**.
See [Canvas](canvas.md) for Canvas-specific behavior.

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
- ~**2 s**, process probe only, while a verified OSC 7501 producer's root record
  decides the state (see [Program status](#program-status-osc-7501)); the report itself
  is applied the moment it arrives.

A key press, a finished command, an OSC 7501 report for a pane without a detected
agent, and the clearing of a record that was deciding the state each wake the loop
immediately instead of waiting for the next tick, and a wake keeps the 300 ms cadence
for about 3 s before a verified producer's pane delegates again.

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
