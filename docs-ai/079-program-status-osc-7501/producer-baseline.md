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

Pending (slice 3).

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
