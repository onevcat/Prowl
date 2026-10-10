# Pi state provider — program status (OSC 7501)

Status: Pi is a verified OSC 7501 producer since
[079 slice 4](../079-program-status-osc-7501/005-pi-verified.md); this is Pi's first and
only state provider. Pi has no file provider: before 079 it had the screen legacy detector
alone (`legacy.detector`, Working/Idle, never Blocked), and that detector stays as the
fallback for Pi versions that do not report and for `PI_PROGRAM_STATUS=0`.

## What decides the state

`ProgramStatusSupport.level(for: .pi) == .verified` in
`App/Sources/Domain/AgentDetection/ProgramStatusEvidence.swift`. The root record Pi 1.1.0
and later writes (`app=pi`) is the first-priority state evidence, applied the moment the
report arrives (`osc.working`, `osc.blocked.<kind>`, `osc.idle`, `osc.done`, `osc.error`);
while it decides, the detection loop runs on the delegated schedule (process probe and
session resolution every 2 s, no screen read) and `screen_reason` is `screen.delegated`.
Pi sends `idle` within about 10 ms of the query echo, before the first probe has bound the
agent, so the report wakes the probe and the first observe pulls the store snapshot. A
`clear` (ctrl+d) withdraws the authority and the next poll reads the screen again with the
`legacy.detector` reason; a confirmed exit after OSC 133 releases the entry.

Blocked exists for Pi only through the protocol: Pi's built-in tools never ask for
confirmation and Pi has no permission setting, so `blocked` comes from extension dialogs
(`ctx.ui.confirm` → `osc.blocked.permission`; `ctx.ui.select`, `input`, `editor` →
`osc.blocked.question`) and from an OAuth login wait (`kind=auth`). A provider failure
during a turn is `error`: the pane reads Idle with `osc.error`, badge-eligible, held until
the next report. Pi's own selectors (`/model`, `/settings`) send nothing, so the previous
root state stands while they are open (no regression: Pi never had Blocked). The managed
`-e prowl-hooks.ts` extension of Agent Profile launches is untouched and remains the exact
path; Oh My Pi is a separate agent whose `app` is unknown and stays unverified.

The root-only rule applies: a `pi-subagents` card still running after the root is `done`
leaves the pane Idle; the fallback rule `hasPiRunningAsyncSubagentCard` keeps Working only
for versions that do not report. Wrapper programs are fenced by `app`: a root with another
`app` is logged once as unmapped, a root without `app` is ineligible, a root with `app=pi`
is attributed to the pane's Pi.

## Boundaries observed (Pi 1.1.0, isolated Debug instance, slice 4 replay)

| Pi boundary | Observed |
| --- | --- |
| launch | `idle` arrives before the first probe binds the agent; the report wakes the probe and the first roster entry is already `osc.idle`, delegated |
| prompt, turn end | `osc.working` on submit (≈ 100 ms through the CLI), `osc.done` at the end of the turn (Done badge while unviewed) |
| interrupt (Esc) | `osc.idle` ("Operation aborted"), not `error` |
| extension dialog `ctx.ui.confirm` | `osc.blocked.permission`; answering returns `osc.working` then `osc.done` |
| extension dialog `ctx.ui.select` | `osc.blocked.question`; same return path |
| built-in selectors (`/model`, `/settings`) | no report; the previous root state stands (documented gap, no regression) |
| provider auth failure (expired Anthropic OAuth) | `osc.working` then `osc.error` within a second; held until the next report; reads as Idle with the Done badge |
| ctrl+d, `kill -9` | the entry is released by the fresh probe after OSC 133 (tens to hundreds of milliseconds through the CLI) |
| relaunch in the same pane | one `legacy.detector` poll, then the new process's own `osc.idle`; the predecessor's records are fenced by arrival time |
| `PI_PROGRAM_STATUS=0`, < 1.1.0 | no reports: `legacy.detector` from the screen rules, unchanged |
| Agent Profile launch (managed `-e prowl-hooks.ts`) | the Profile keeps its exact hook channel while OSC supplies the pane state and takes part in idle admission; the kickoff and a later assignment completed through explicit dispatch receipts, and the idle wait and the re-dispatch admission succeeded |
| `pi-subagents` running after root `done` | not exercised in the replay (root-only rule by code: the pane reads Idle; the fallback `hasPiRunningAsyncSubagentCard` applies only without reports) |

## References

- [079 plan](../079-program-status-osc-7501/000-plan.md), [producer baseline](../079-program-status-osc-7501/producer-baseline.md)
  (what Pi sends, the gate extension used to replay `blocked`).
- [Shared architecture](architecture.md); [Claude provider](claude.md) for the native
  provider interplay that Pi does not have.
