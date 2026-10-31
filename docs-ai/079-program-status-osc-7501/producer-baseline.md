# OSC 7501 producer baseline

Living document: what each producer actually sends when the terminal answers the support
query. Re-run the harness and update the table before enabling OSC-first for a new producer
version, and whenever a producer upgrade changes Prowl's detection. "Not observed" means the
scenario was run and no report arrived, not that the producer never sends one.

## Harness

```sh
# answer the probe, accept Claude's trust dialog (Down, Enter), send one prompt
scripts/program_status_probe.py --seconds 40 \
  --keys '3:\x1b[B;3.3:\r;7:reply with just the word ok\r' -- claude

# pi: prompt, then ctrl+d twice to exit
scripts/program_status_probe.py --seconds 32 \
  --keys '4:reply with just the word ok\r;24:\x04;25:\x04' -- pi

# pi blocked: gate the bash tool with an extension dialog, answer it with Enter (Yes)
scripts/program_status_probe.py --seconds 48 \
  --keys '4:use the bash tool to run: touch probe-touch.txt. Then reply with just the word ok\r;16:\r;24:\r;42:\x04;43:\x04' \
  -- pi -e /path/to/confirm-gate.ts

# omp: type the prompt, press Enter separately (an Enter in the same write is pasted text);
# --approval-mode always-ask makes the bash tool ask before it runs
scripts/program_status_probe.py --seconds 40 \
  --keys '5:use the bash tool to run exactly: touch probe-touch.txt . Then reply with just the word ok;5.6:\r;16:\r;30:\x04;31:\x04' \
  -- omp --profile prowl-probe --model deepseek/deepseek-flash --approval-mode always-ask
```

Pi's built-in tools never ask for confirmation and Pi has no permission setting, so `blocked`
only comes from extension dialogs (`ctx.ui.confirm` → `kind=permission`; `ctx.ui.select`,
`input`, `editor` → `kind=question`) and from an OAuth login wait (`kind=auth`). The gate
extension for the replay is:

```ts
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash" || !ctx.hasUI) return undefined;
    const allowed = await ctx.ui.confirm("Run bash?", String(event.input.command));
    return allowed ? undefined : { block: true, reason: "Blocked by user" };
  });
}
```

Swap `ctx.ui.confirm(...)` for `ctx.ui.select("Run bash?", ["Yes", "No"]) === "Yes"` to
replay `kind=question`.

The harness spawns the program in a pty (120×40, `TERM=xterm-256color`, `CLAUDE*` variables
removed), echoes `OSC 7501 ; ?` with the producer's terminator, answers DA1 and the kitty
keyboard query, sends scripted keys, and prints each report with its offset in seconds.
Run it from a disposable directory: the prompts call the model and Claude's first run in a
new directory shows the trust dialog.

## Claude Code 2.1.296 (2026-10-10, macOS, default permission mode)

| Scenario | Reports (offset from launch) |
| --- | --- |
| Launch | query at 0.25–0.5 s together with DA1 and `CSI ? u`; nothing until the trust dialog is answered |
| Trust dialog accepted, TUI mounted | `state=idle:app=claude-code` |
| Prompt submitted | `state=working:app=claude-code` within 0.05 s of Enter |
| Tool running | `state=working:app=claude-code:msg=<base64>` (msg was the tool description, e.g. "Listing files in current directory with details") |
| Bash approval prompt | `state=blocked:app=claude-code:kind=permission:msg=<base64 "approve Bash: touch probe-touch.txt">` |
| Turn finished | `state=done:app=claude-code` |
| Background subagent (`run_in_background`, 2026-10-11) | root `state=working` on submit; when the Agent tool starts, root `state=working:app=claude-code:msg=<base64 tool description>` and a child record `state=working:app=claude-code:id=<agent id>:title=<base64 description>` in the same instant (0.05 s before the `SubagentStart` hook); root `state=working` re-sent without `msg` 1.1 s after the `Stop` hook of Claude's own turn, while the TUI shows "Waiting for 1 background agent to finish"; `state=clear:id=<agent id>` when the agent finishes (0.02 s before `SubagentStop`); the result is then auto-submitted as a new turn (`UserPromptSubmit`, `Stop`) and only after it root `state=done` |
| `/clear` (2026-10-11) | `state=working` then `state=idle` 0.04 s later; no `clear` |
| In-process `/resume`, session picked (2026-10-11) | `state=idle:app=claude-code` 0.1 s after the selection; no `clear` |
| Exit (trust dialog declined, or quit) | `state=clear` (`/exit`: a momentary `working`, then `clear`, repeated up to three times) |

Not observed by the harness: a report for the trust dialog itself; `question`/`auth` kinds
(both observed inside Prowl, see below); a child `blocked` record. `ls -la` ran without an
approval prompt (read-only command), so a write command is needed to reproduce `blocked`.
Child records carry `title` (the agent description) rather than `msg`; the root never
leaves `working` while a child is live, so OSC alone cannot tell "the root's own turn
ended, only children remain" (the `Stop` hook and the screen row can).

## Pi 1.1.0 (2026-10-10, macOS, onevcat's settings, model gpt-6-astra)

| Scenario | Reports (offset from launch) |
| --- | --- |
| Launch | query at 0.4–0.5 s; `state=idle:app=pi` within 0.01 s of the echo, before the TUI finished drawing |
| Prompt submitted | `state=working:app=pi` within 0.05 s of Enter |
| Turn finished | `state=done:app=pi` |
| Escape during a turn | `state=idle:app=pi` ("Operation aborted"), not `error` |
| ctrl+d at the prompt | `state=clear`, then exit |
| `/model` selector open and dismissed | not observed (no report either way; built-in selectors are not extension dialogs) |
| Bash tool (`touch`), no gate extension | ran without a confirmation: `working` → `done`, no `blocked` |
| Bash tool behind `ctx.ui.confirm` | `state=blocked:app=pi:kind=permission:msg=<base64 "Run bash?">` 4 s after Enter (model latency); msg is the dialog title only, not the command |
| Bash tool behind `ctx.ui.select` | `state=blocked:app=pi:kind=question:msg=<base64 selector title>` |
| Dialog answered (Enter = Yes) | `state=working:app=pi` within 0.01 s, then `state=done:app=pi` 2 s later |
| Provider auth failure during a run (expired Anthropic OAuth) | `state=working` then `state=error:app=pi:msg=<base64 first error line>` 0.3 s later; no `done`; stays `error` until ctrl+d → `clear` |
| Missing API key for the provider | pre-flight error in the TUI, the run never starts: no `working`, no `error` |

Not observed: `kind=auth` (Pi sends it while an OAuth login waits for the browser; not run
because it opens a real login flow), child records. `working`/`done` carry `msg` only when
the session has a name. The `error` msg carried a URL and a server response body: keep it
out of durable logs. Pi 1.0.2 (the previous local version) sent no query.

## Oh My Pi 18.10.0 (2026-10-12, macOS, isolated `--profile`, model deepseek/deepseek-flash)

OSC 7501 reporting shipped in omp 18.8.7 (`terminal.programStatus`, default on). omp writes
the root record only (`app=omp`, never an `id`), with `msg` on `blocked` and `error` alone.

| Scenario | Reports (offset from launch) |
| --- | --- |
| Launch | no query; `state=idle:app=omp` at 0.6–0.8 s, as soon as the TUI mounts |
| Prompt submitted | `state=working:app=omp` within 0.05 s of Enter |
| Turn finished | `state=done:app=omp` |
| Escape during a turn | `state=idle:app=omp` 0.2 s after the key, not `error` |
| Bash tool with `--approval-mode always-ask` | `state=blocked:kind=permission:app=omp:msg=<base64 "Allow tool: bash Command: touch probe-touch.txt">` 1 s after Enter (model latency) |
| Approval answered (Enter = allow) | `state=working:app=omp` within 0.1 s, then `state=done:app=omp` 0.8 s later |
| `ask` tool | `state=blocked:kind=question:app=omp:msg=<base64 question text>`; Enter → `working` → `done` |
| Invalid API key (`--api-key`) | `state=working` then `state=error:app=omp:msg=<base64 provider error>` 0.4 s later; no `done` |
| bash `async: true` job (`sleep 40`) | `working` on submit and kept while the job runs, although the model replied at once; `done` only after the job finished and the injected result turn ended (45 s) |
| ctrl+d at the prompt | `state=clear`, then exit |
| `terminal.programStatus: false` (`--config` overlay) | no reports |

Not observed: `kind=auth`, child records (omp's run-status module writes the root alone).
omp sends no support query, which Prowl does not require. The `error` msg carries the
provider's response text (request id, masked key): keep it out of durable logs. Like a
Claude Code background subagent, an omp async job keeps the root `working`, so the pane
stays Working until the job's result turn ends.

## Replay rules

- A producer's row is evidence for that version only; re-run on upgrade before trusting a
  new state or kind.
- Timings are for ordering (query before DA1, idle after mount), not latency guarantees.
- Keep `msg` out of durable logs by default; it is untrusted program text.

## Codex 0.163.0 (2026-10-17, macOS)

Release source: [OpenAI PR #52725](https://github.com/openai/codex/pull/52725),
included in [rust-v0.163.0](https://github.com/openai/codex/releases/tag/rust-v0.163.0).
`codex-rs/tui/src/terminal_program_status.rs` emits a root record whenever stdout
is a terminal, including multiplexers; no support query or OSC-specific opt-out.
`chatwidget/status_surfaces.rs` chooses Blocked for action-required UI, then Working
for a running task or live unified-exec process, otherwise Idle. No child records,
kind, message, Done, or Error are encoded.

Replayed with `scripts/program_status_probe.py`, `--no-alt-screen`, a trusted
scratch directory, and the configured GPT-6-Astra model at low reasoning effort.
The approval run used `approval_policy="on-request"`, `sandbox_mode="read-only"`,
and an explicit request for a harmless `touch` with `sandbox_permissions=require_escalated`.
The question run entered `/plan` and requested `request_user_input`.

| Scenario | Reports observed |
| --- | --- |
| Startup | `state=idle:app=codex`; a short startup `working` → `idle` transition also occurred before input |
| Prompt submitted | `state=working:app=codex`, about 0.2 s after Enter |
| Reply complete | `state=idle:app=codex` (not `done`) |
| Command approval | `state=blocked:app=codex`, no kind |
| Plan-mode question | `state=blocked:app=codex`, no kind |
| Escape at either blocker | `working` → `idle` within 0.02 s |
| Ctrl+D at the composer | `state=clear`, without app |

## Amp, Antigravity, Devin, Droid, Grok Build (2026-10-31, macOS)

Recorded by running each TUI under `script -q -F` inside a Prowl pane, so real Ghostty
answered the capability queries. Do this for OpenTUI and similar TUIs: the pty harness
does not answer enough of their queries, and they never reach the support query there.
Versions: Amp 0.0.1793376030, Antigravity 1.4.11, Devin 3000.11.234, Droid 1.0.0, Grok Build
1.0.70. Droid used DeepSeek (`--settings` with `sessionDefaultSettings.model`; the Droid TUI
has no `-m`, it reads that as a prompt). The others used their signed-in default models.

| Scenario | Amp | Antigravity | Devin | Droid | Grok Build |
| --- | --- | --- | --- | --- | --- |
| Support query | yes | yes | no | yes | yes |
| `app` | `amp` | `antigravity` | `devin` | `droid` | `grok-build` |
| First report | `idle`, only when the first prompt is entered | `blocked:kind=auth` then `idle` 0.03 s later | `idle` on mount | `idle` on mount | `idle` on mount |
| Trust dialog | not shown | `blocked:kind=permission` | not shown | not shown | `blocked:kind=permission` |
| Prompt | `working` | `working` | `working` (`msg` Thinking, Typing, Running tools) | `working` | `working` (`msg` per stage) |
| Turn finished | `done`, repeated when the thread title arrives | `done` (`msg` = reply excerpt) | `done` | `done` | `done` |
| Cancel | Esc Esc → `done` | Esc → `idle` | Esc Esc → `idle` | Esc → `idle` | Ctrl+C → `idle` (Esc does nothing) |
| Tool approval | `blocked`, no kind (needs an `ask` permission rule) | `blocked:kind=permission` | `blocked:kind=permission` | `blocked:kind=permission` (only when the model rates the command above the autonomy level) | `blocked:kind=permission` (not in `always-approve`, Shift+Tab leaves it) |
| Question tool | `blocked`, no kind | `blocked:kind=question` | `blocked:kind=question` | `blocked:kind=question` | `blocked:kind=question` |
| Provider failure | not run | not run | not run | `error`, no `msg` (invalid key) | not run |
| Exit | not recorded | no `clear` | `clear` | no `clear` | `clear` |
| Child records | none | none | none | none | `id=s1` with `title`, mirrors the root |

Grok Build also reports `blocked:kind=auth` while signed out. `msg` can carry reply text
(Antigravity) or the session title (Amp): keep it out of durable logs.

## Agents without a producer (2026-10-31)

Checked on the newest public release. "Live" ran the TUI in a Prowl pane and captured the
bytes; "static" searched the shipped JavaScript or binary for the sequence.

| Agent | Version | Evidence | Result |
| --- | --- | --- | --- |
| Cline | 3.0.74 | live, static | no query, no report |
| Copilot | 1.0.105 | live, static | no query, no report |
| Cursor | 2026.10.22 | static (2026.05.09 live) | none |
| Gemini | 0.66.0 | static | none; [#29918](https://github.com/google-gemini/gemini-cli/pull/29918) is open |
| Kimi | 1.52.0 | static | none |
| OpenCode v1 | 1.19.5 | live, static | no query, no report |
| Qoder | 1.1.81 | live, static | no query, no report |
| Qwen | 0.26.4 | static | none; [#13994](https://github.com/QwenLM/qwen-code/pull/13994) is open |
| TRAE | 0.213.1 | static | none |

OpenCode v2 (2.2.4) does report: `app=opencode`, a root summary plus one child per pending
session, `working` → `idle` with no `done` or `error`
([#60411](https://github.com/anomalyco/opencode/issues/60411)), and no root `clear` on exit
([#60466](https://github.com/anomalyco/opencode/issues/60466)). It stays unverified: Prowl
supports the v1 line, and v2 needs its own work.

## Verification inside Prowl

Filled in by the slice that marks a producer verified (slices 3 and 4 of
[000-plan.md](000-plan.md)). Each row is one baseline scenario replayed in an isolated Debug
instance, with the `detection_reason` that `prowl agents --json` reported and the schedule the
pane was on. A producer is not flipped to `.verified` before its table is complete.

### Claude Code

Replayed on 2026-10-11 with Claude Code 2.1.296 against the slice 3 build (Claude
`.verified`) in an isolated Debug instance (`CFFIXED_USER_HOME`, own socket, the real
`~/.claude/sessions` and `~/.claude/projects` linked read-only into the isolated home so
the native fallback is observable). `detection_reason` and `screen_reason` are what
`prowl agents --json` reported; timings are CLI-polled (each includes the `prowl send`
round trip and a poll interval of 250 ms) and are for ordering, not latency guarantees.
"Delegated" means `screen_reason` was `screen.delegated`, i.e. the pane was on the 2 s
probe-only schedule.

| Scenario | `detection_reason` (schedule) | Notes |
| --- | --- | --- |
| Launch, trust dialog shown | `screen.logUnavailable` / `claude.blockedPrompt`, Blocked (active) | no report before the dialog is answered, as in the harness |
| Trust dialog accepted, TUI mounted | `osc.idle` (delegated) | 620 ms after the keystroke; the pane showed Done, which `osc.idle` cannot earn: the legacy 300 ms poll crossed Blocked → Idle on the mounting TUI before the report arrived (see 004) |
| Prompt submitted | `osc.working` (delegated) | 90–340 ms after `prowl send` |
| Tool running (`ls`, `touch`) | `osc.working` (delegated) | `msg` is neither logged nor published |
| Bash approval prompt | `osc.blocked.permission` (delegated) | `prowl agents read` reads the fresh screen and fills `blocker.text` from the dialog |
| Approval accepted | `osc.working` → `osc.done` (delegated) | Done badge while unviewed; viewing the pane turned it into Idle within 76 ms |
| AskUserQuestion | `osc.blocked.question` (delegated) | not observed by the harness; answering gives `osc.working` → `osc.done` |
| Foreground subagent (Agent tool) | `osc.working` → `osc.done` (delegated) | the pane follows the root; child records are not observable through the CLI |
| Background subagent (`run_in_background`) | `osc.working` (delegated) for the whole wait, then `osc.done` | 2.1.296 keeps the turn open ("Waiting for 1 background agent to finish"); the fresh screen rule `claude.backgroundWork` agrees |
| `/compact` | `osc.working` (delegated) for ~36 s, then `osc.done` | the fresh screen rule `claude.spinner` agrees |
| Escape during a turn | `osc.idle` (delegated) | 96 ms after the key; an earlier unviewed badge stays |
| `/clear` | `osc.working` then `osc.idle` (delegated) | same PID; `working` lasted one poll. With the registry as the session (2026-10-11): the roster's `session` moved to the new id (`process_log` / `exact`, with the new transcript's path) 2.1 s after the command with no further input |
| In-process `/resume` to an earlier session of the same process (2026-10-11) | `osc.idle` (delegated) | no further input after the picker's Enter: the roster's `session` moved back to the resumed id with its transcript path 4.2 s later; the registry agreed. Before the registry change this case was stuck until the next input |
| Invalid `ANTHROPIC_API_KEY` accepted at launch | `osc.idle` on mount, then `osc.blocked.auth` (delegated) on the first prompt | held until the user acts; the fresh screen is an idle composer with the error line |
| `/exit` | entry released | 793 ms and 545–735 ms in later runs, CLI-polled; `main` took 1.8–2.1 s |
| `kill -9` | entry released | 394 ms, CLI-polled |
| Relaunch in the same pane | `screen.logUnavailable` / `fallback.noRuleMatched` for the banner, then `osc.idle` (delegated) | 955 ms after `prowl send`; its own report, no predecessor state |
| Close and undo | `osc.done` (delegated) on the restored pane | the retained store was pulled back with no new report; undo through `prowl key <pane> cmd-z` restored the pane in 73 ms |
| `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` | `native.idle` / `claude.idleComposer`, `native.working` / `claude.spinner` (active) | the registry path, unchanged; without the registry link the reason is `screen.logUnavailable` |
| Agent Profile launch (`Claude Test`: sonnet, bypass permissions, managed hooks) | `osc.working` → `osc.done` (delegated) | launch dispatch receipt `succeeded`; `agents wait --until idle` and a re-dispatch resolved; `signals.channels` kept `hook_claude` at `exact` |

Not exercised: `kind=auth` from a real OAuth login wait, child `blocked` records (no
subagent asked for a permission during the replay), and `CLAUDE_CODE_SESSION_KIND=bg`.

### Pi

Replayed on 2026-10-11 with Pi 1.1.0 (model `gpt-6-astra`, onevcat's settings) against
the slice 4 build (Pi `.verified`) in an isolated Debug instance (`CFFIXED_USER_HOME`, own
socket; the pane cwd was the real `/private/tmp/...` path). `detection_reason` and
`screen_reason` are what `prowl agents --json` reported; timings are CLI-polled (they
include the `prowl send` round trip and a poll interval of 250 ms) and are for ordering,
not latency guarantees. "Delegated" means `screen_reason` was `screen.delegated`.

| Scenario | `detection_reason` (schedule) | Notes |
| --- | --- | --- |
| Launch | `osc.idle` (delegated) | the first roster entry already carried the report (605 ms after `prowl send`); the probe's own diagnostic still read the screen as `legacy.detector` idle |
| Prompt submitted | `osc.working` (delegated) | 90–130 ms after `prowl send` |
| Turn finished | `osc.done` (delegated) | Done badge while unviewed |
| Escape during a turn | `osc.idle` (delegated) | 93 ms after the key ("Operation aborted") |
| `/model` selector open | unchanged `osc.idle` (delegated) | no report either way, as in the harness; the cached list had no anthropic models, so the selector could not be used for the error row |
| Bash tool behind `ctx.ui.confirm` (`-e confirm-gate.ts`) | `osc.blocked.permission` (delegated) | 3.5 s after the prompt (model latency); `agents read` reports `AGENT_UNSUPPORTED` for Pi, as its contract says; Enter → `osc.working` → `osc.done` 1.7–2.3 s later |
| Bash tool behind `ctx.ui.select` (`-e select-gate.ts`) | `osc.blocked.question` (delegated) | 3.4 s after the prompt; Enter → `osc.working` → `osc.done` |
| Provider auth failure (`pi --provider anthropic --model claude`, expired OAuth) | `osc.idle` on mount, `osc.working` then `osc.error` (delegated) on the first prompt | 736 ms after `prowl send`; held (still `osc.error` 5 s later); status `done` (badge-eligible) |
| ctrl+d at the prompt | entry released | 69 ms CLI-polled after the key (`clear` plus the shell's OSC 133 D; a second ctrl+d closes the shell); 243–258 ms in later runs |
| `kill -9` | entry released | 143 ms CLI-polled |
| Relaunch in the same pane | `legacy.detector` for one poll, then `osc.idle` (delegated) | 645 ms after `prowl send`; its own report, no shadow line (verified producers log none) |
| `PI_PROGRAM_STATUS=0 pi` | `legacy.detector` throughout (active) | idle → working → done from the screen rules; zero `[ProgramStatus]` lines |
| Agent Profile launch (`Pi Test`: gpt-6-astra, managed `-e prowl-hooks.ts`) | `osc.working` → `osc.done` (delegated) | launch dispatch receipt `succeeded`; `signals.channels` carried `hook_pi` at `exact`; `agents wait --until idle` and a re-dispatch resolved with a second receipt |

Not exercised: `kind=auth` from a real OAuth login wait, a `pi-subagents` card running after
the root `done` (the extension is installed but the scenario needs a long-running subagent
and was not run), and child records. The Done → viewed → Idle step could not be reproduced
in this run because the isolated window never reported itself visible on the locked
screen; it is the unchanged `markAgentSeen` path and was reproduced in slice 3.

### Oh My Pi

Replayed on 2026-10-12 with Oh My Pi 18.10.0 (`--profile prowl-probe`, model
`deepseek/deepseek-flash`) against the 079.006 build (Oh My Pi `.verified`) in an isolated
Debug instance (`CFFIXED_USER_HOME`, own socket; the pane cwd was a repository under
`~/.local/share`). `detection_reason` and `screen_reason` are what `prowl agents --json`
reported; timings are CLI-polled (they include the `prowl send` round trip and a poll
interval of 250 ms) and are for ordering, not latency guarantees. "Delegated" means
`screen_reason` was `screen.delegated`.

| Scenario | `detection_reason` (schedule) | Notes |
| --- | --- | --- |
| Launch | `osc.idle` (delegated) | about 1 s after `prowl send`; a relaunch in the same pane showed one `legacy.detector` poll first, then its own `osc.idle` 0.7 s after `prowl send` |
| Prompt submitted | `osc.working` (delegated) | 150–240 ms after `prowl send` |
| Turn finished | `osc.done` (delegated) | Done badge while unviewed |
| Escape during a turn | `osc.idle` (delegated) | 115 ms after the key; the earlier unviewed badge stayed (status `done`) |
| Bash tool with `--approval-mode always-ask` | `osc.blocked.permission` (delegated) | 2 s after the prompt (model latency); `agents read` reports `AGENT_UNSUPPORTED` for omp, as its contract says; Enter → `osc.working` → `osc.done` 1.5 s later |
| `ask` tool | `osc.blocked.question` (delegated) | Enter → `osc.working` → `osc.done` 1 s later |
| bash `async: true` job (`sleep 30`) | `osc.working` (delegated) for the whole job, then `osc.done` | `agents wait --until idle` armed while the job ran resolved only at `osc.done` (27 s later); `agents dispatch` on the idle pane was then admitted |
| Invalid API key (`--api-key`) | `osc.idle` on mount, `osc.working` then `osc.error` (delegated) on the first prompt | 270 ms between the two; status `done` (badge-eligible) |
| ctrl+d at the prompt, fresh session | entry released | within 0.3 s, CLI-polled (`clear` plus the shell's OSC 133 D) |
| ctrl+d or `kill -9` after a turn | one or more `legacy.detector` polls, then released | 2.1–3.4 s: omp opens each user message it draws with `133;A` and closes it with `133;B`, `133;C`, `133;D;0`; the inner C replaces the shell's command timer and the inner D consumes it, so the shell's D at exit raises no `COMMAND_FINISHED` and the six-miss release applies (see 006). `kill -9` on a fresh session released within 0.25 s |
| `terminal.programStatus: false` (`--config` overlay) | `legacy.detector` throughout (active) | idle → working → done from the screen rules |
| Agent Profile launch (`OMP Test`: deepseek-flash, unrestricted, managed `--hook prowl-hooks.ts`) | `osc.working` → `osc.done` (delegated) | launch dispatch receipt `succeeded`; `signals.channels` carried `hook_omp` at `exact` (`verified_live`); `agents wait --until idle` and a re-dispatch resolved with a second receipt |

Not exercised: `kind=auth` (omp's run-status module has no auth kind), child records (omp
writes none), and the Done → viewed → Idle step (the unchanged `markAgentSeen` path).

### Codex

Replayed on 2026-10-17 with Codex 0.163.0 and the 079.007 Debug build in a separate
instance, using an isolated preferences home and CLI socket. Scratch workspace:
`/Users/onevcat/.prowl-codex-osc-probe`. Observations below came from the running
app's bundled CLI, not injected OSC reports. `agents` reported `screen.delegated`
while the root decided; on-demand `agents read` still read the current screen.

| Scenario | Observation |
| --- | --- |
| TUI mount | `osc.idle`; entry appeared within 0.83 s of launch |
| Plain reply | `osc.working` → `osc.idle`; `agents read` returned `complete` with the expected marker and exact session; idle wait resolved after its 2 s settling window |
| Command approval | `osc.blocked.unspecified`; semantic read returned the actual approval text and `pending`; a 3 s idle wait timed out while blocked |
| Approve the command | `osc.working` within 0.04 s, then `osc.idle`; the scratch file existed and the result marker was complete |
| Plan-mode question | `osc.blocked.unspecified`; semantic read returned the actual choices; answer → `osc.working` → `osc.idle` |
| Escape during a running turn | `osc.idle` within 0.03 s; semantic result remained `incomplete`, not successful |
| `/new` | root remained idle; the public session still named the preceding session before the next prompt. The next turn resolved the new session and returned its distinct result marker (`transcript_match`, high). OSC carries no identity |
| Ctrl+Z / `fg` | suspended entry disappeared; foreground resume restored `osc.idle`. A trailing kitty key-release sequence reached the shell, so Ctrl+U was needed before `fg` |
| Normal Ctrl+D exit | authority withdrew (`screen.noLiveTurn`), then the entry disappeared within 0.55–0.84 s of the key |
| Profile launch and redispatch | two explicit dispatch receipts succeeded; `osc.working` → `osc.idle` and semantic result remained available. The first fixture's `notify=[]` correctly degraded the managed hook; this is not evidence of a verified hook |
| Profile with valid notifier | No launch degradation; explicit dispatch succeeded, `hook_codex` was `verified_live` at `exact`, and state remained `osc.working` → `osc.idle` |
| Abrupt exit | A separately launched TUI was killed by its recorded PID; its entry disappeared within 0.29 s without a producer `clear` |

Not exercised: authentication UI, remote/multiplexed sessions, provider failures,
external editor, or live child/background work. Source inspection establishes the
coarse root semantics, not live acceptance of those cases. Older versions were not
installed; no-report and clear fallback are covered by the automated coordinator tests.

### Amp, Antigravity, Devin, Droid, Grok Build

Replayed on 2026-10-31 with the 079.008 Debug build in an isolated instance (`CFFIXED_USER_HOME`,
own socket, launched with `open -n` so that the panes can reach the Keychain). Offsets are from
the key or command and CLI-polled at 250 ms.

| Scenario | Observation |
| --- | --- |
| Launch | `osc.idle` within 2 s for four. Amp stays on `legacy.detector`: its only `idle` is ignored (see 008), and `osc.working` takes over 2–3.5 s into the first turn |
| Trust dialog (Antigravity, Grok Build) | `osc.blocked.permission` 0.7 s after launch; Enter → `osc.idle` within 0.3 s |
| Prompt, finish | `osc.working` within 0.5 s, except Amp's first turn (above); `osc.done`, Done badge while unviewed |
| Cancel | `osc.idle` within 0.4 s for Antigravity, Devin, Droid, Grok Build; `osc.done` for Amp, which reports the cancel as `done` |
| Approval | `osc.blocked.permission` for four; `osc.blocked.unspecified` for Amp. Enter → `osc.working` within 0.3 s |
| Question tool | `osc.blocked.question` for four; `osc.blocked.unspecified` for Amp |
| Invalid key (Droid) | `osc.idle` on mount, `osc.working` then `osc.error` 0.3 s later |
| `agents wait --until idle` while working | resolved only after the turn, for Amp, Antigravity, Droid, Grok Build. A wait armed right after Amp's first prompt resolved after 18.3 s, at the end of that turn; the pane read Working throughout |
| Session rotation | Antigravity `/clear` moved to the new id in 2.8 s and Devin `/clear` in 0.7 s, both `exact`. Amp and Grok Build `/new` kept the old id, the same as the control build. Droid had no session in either build |
| Exit | released in 0.5 s (Droid `/quit`), 0.3 s (Amp Ctrl+C twice), 0.7 s (Antigravity `/exit`), 1.5–2.1 s (Grok Build, Devin `/exit`) |
| `kill -9` | released in 0.2–0.3 s (Amp, Antigravity, Droid, Grok Build), 3.0 s (Devin) |
| Agent Profile launch and dispatch | Amp, Antigravity, Devin, and Grok Build: two receipts `completed`, `osc.done` afterwards. Droid: `hook_droid` `verified_live` at `exact`; the DeepSeek model answered without calling `dispatch-complete`, and the Stop hook closed the receipt as `DISPATCH_INCOMPLETE` |

Not exercised: `kind=auth` inside Prowl, Amp, Antigravity, Devin, and Grok Build provider
failures, a Grok Build child `blocked` record, long-running subagents, and remote panes.
