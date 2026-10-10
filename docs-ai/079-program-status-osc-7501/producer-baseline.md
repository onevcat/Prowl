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
| Exit (trust dialog declined, or quit) | `state=clear` |

Not observed: a report for the trust dialog itself; child records (`id=`) — no subagent
scenario was run; `question`/`auth` kinds. `ls -la` ran without an approval prompt (read-only
command), so a write command is needed to reproduce `blocked`.

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

## Replay rules

- A producer's row is evidence for that version only; re-run on upgrade before trusting a
  new state or kind.
- Timings are for ordering (query before DA1, idle after mount), not latency guarantees.
- Keep `msg` out of durable logs by default; it is untrusted program text.

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
| `/clear` | `osc.working` then `osc.idle` (delegated) | same PID; `working` lasted one poll |
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

Pending (slice 4).
