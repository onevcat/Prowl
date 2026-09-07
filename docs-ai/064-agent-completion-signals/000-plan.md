# 064 — Agent Completion Signals: Plan

| | |
| --- | --- |
| **Status** | In progress — S1 #715, S2 #718, S3 wave 1 #721/#723/#725/#728, and follow-ups #732/#736 shipped in v2026.8.29; #733 re-dispatch (#741) and #726 T0 (#739) shipped in R2a; #726 T1a inventory/configuration preflight implemented in [016](016-t1-contract-test-plan.md) for R2b; eight-runtime headless checks verified; T1 verification and scoped publication merged (#769); S4/S5 planned |
| **Anchor date** | 2026-08-22 |
| **Primary PRs** | #715 (S1); #718 (S2); #721, #723 (S3a); #725 (S3b); #728 (S3c); #732 (012); #736 (013); #741 (re-dispatch); #739 (T0); #767 (runtime contracts, merged) |
| **Related** | [063 agent-workflows](../063-agent-workflows/000-plan.md) (consumer; defines the `ObservedAgentState` observer this entry feeds), [030 agent-status-detection](../030-agent-status-detection/000-plan.md), [045 native-agent-session-detection](../045-native-agent-session-detection/000-plan.md), [055 agent-profile-runtimes](../055-agent-profile-runtimes/000-plan.md), [059 agent-transcript-snapshots](../059-agent-transcript-snapshots/000-plan.md), [060 cli-targeting-and-contract-governance](../060-prowl-cli-targeting-and-contract-governance/000-plan.md), [#473](https://github.com/onevcat/Prowl/issues/473), [#676](https://github.com/onevcat/Prowl/issues/676), `docs/components/agent-detection.md`, `docs/components/cli.md` |

## Background

Prowl's per-pane agent status (`working` / `blocked` / `idle` / `done`) comes from
heuristic screen and process detection (030/045, `supacode/Domain/AgentDetection/PaneAgentState.swift`).
Explicit screen states apply immediately since 030.015 retired the former 3 s Working hold.
The detector is good enough for the sidebar and Active Agents, and #676 documents the states
it still misreports. Two consumers need something stronger:

- An agent orchestrating other agents through the `prowl` CLI (the "route B" flow that
  onevcat runs daily and that 063 formalizes) has to *wait* for a sibling agent to finish.
  Today that means a hand-written polling loop over `prowl agents --json`, a completion
  signal based on a conventional file name, and no way to tell a trustworthy "finished"
  from a heuristic guess. Ten rounds of CLI-driven adversarial review during the 063
  design (2026-08-22) reproduced every one of these pains.
- The 063 runner's watchdog nudges and escalates on heuristic state; a deterministic
  "turn complete" / "needs input" event would make those nudges exact instead of guessed.

Several agent CLIs already expose deterministic, agent-reported events — hooks, notify
commands, plugin events — and most can be enabled per launch without touching the user's
global configuration. Prowl launches agents itself (053/055), so it can attach such hooks
at launch and have the agent report to Prowl through the bundled `prowl` binary.

## Goals

- Introduce one **agent signal bus** per pane that merges four layers of evidence, each
  tagged with `source` and `confidence`:
  0. cooperative signals — `prowl agents signal` (and 063's `prowl workflow deliver`);
  1. native hooks installed by Prowl at launch (agent-reported, exact);
  2. deterministic observations — native transcript turn-end markers (059), agent process
     exit, OSC progress/notification sequences the CLI emits itself;
  3. heuristic screen/process detection (existing).
- Add `prowl agents signal <event>` so any agent (or a hook it runs) can report
  `turn-ended` / `needs-input` / `session-start` / `session-end`, attributed by the caller
  pane (a hook is a child of the agent process, so process ancestry still resolves the
  pane). `turn-ended` deliberately means a runtime turn edge, not assigned-task or workflow
  completion.
- Add `prowl agents wait <pane> --until … [--timeout] [--min-confidence] [--include-screen]`
  that resolves on the bus and reports *what kind* of signal it got.
- Make `prowl agents` honest about what each pane can offer (`signals` field) and make
  hook installation self-checking with visible degradation.
- Keep per-runtime knowledge in the runtime adapters (055 capability model) with a living
  research matrix, so a changed hook API is a one-adapter change.

### Non-goals

- Making heuristic detection itself authoritative. Layer 3 remains a hint.
- Prowl calling an LLM to judge screens. Judgment belongs to the orchestrating agent (the
  skill gives it the screen tail and a rubric); an on-device Foundation Model classifier is
  at most a V2 experiment.
- Editing the user's global agent configuration (`~/.claude/settings.json`, `~/.codex/config.toml`, …).
  Hooks are attached only through launch-scoped flags/config the adapter has verified; a
  runtime without such a channel simply stays at layers 2–3.
- Waiting semantics inside 063 workflows: the runner still completes steps only on
  `prowl workflow deliver`; this entry improves its watchdog and enables 063's V2 observe mode.

## Design / Approach

### The bus and its producers

`WorktreeTerminalManager` gains per-surface signal state feeding the typed multicast
observer first specified in 063 and delivered by this entry's S1 (`ObservedAgentState`:
`snapshot` / `changed` / `removed` / `surfaceClosed`), extended with `.signal(AgentSignal)`
where

```swift
struct AgentSignal: Sendable, Equatable {
  enum Kind { case turnEnded, needsInput, sessionStart, sessionEnd, progress(Int?) }
  enum Source {
    case cooperativeCLI
    case hook(runtime: AgentProfileRuntime, event: String)
    case transcript, process, osc, screen
  }
  enum Confidence { case exact, high, heuristic }
  let kind: Kind; let source: Source; let confidence: Confidence; let timestamp: Date
  let sessionID: String?; let detail: String?; let claimedOrigin: String?
}
```

| Producer | Mechanism | Confidence |
| --- | --- | --- |
| `prowl agents signal` | CLI handler, caller-pane attribution, optional bounded `--origin` (claimed metadata only), `--session`, and `--detail` | exact caller/channel attribution |
| Launch-scoped hooks | adapter capability `signalHooks` renders a Prowl-configured launch-scoped channel that reports native events through the bundled CLI; only validated capability upgrades provenance to `hook` (per-runtime syntax: research matrix) | exact channel attribution |
| Transcript turn-end | 059's reader on the exact/high-attributed transcript, file-watch instead of polling | high/exact |
| Process exit | existing `agentEntryRemoved` | exact |
| OSC | existing progress/notification OSC handling in the Ghostty bridge, surfaced as signals | high |
| Screen/process heuristics | existing detection | heuristic |

Every producer writes to the same per-surface state; the reducer-side consumer (063
runner via `AppFeature`) and the CLI-side consumer (`agents wait` via the multicast
observer) see identical events. Registration and snapshot capture stay one main-actor step.
Each subscriber is independently bounded. If it falls behind, state churn is recovered from
a new snapshot; signal or lifecycle overflow is explicit and S2's waiter re-subscribes before
surfacing an error. Critical events are never silently discarded.

### `prowl agents wait`

```
prowl agents wait <pane> --until idle|blocked|changed|exit [--timeout 1…600]
                 [--min-confidence auto|exact|high|heuristic]
                 [--include-screen <1…200>] [--json]
prowl agents wait --dispatch <id> [--timeout 1…600]
                 [--include-screen <1…200>] [--json]
```

- Snapshot first: return immediately when the current state already satisfies `--until`
  at the required confidence.
- Default `--min-confidence auto`: a fresh exact/high event always matches; if the pane has
  verified-live coverage for the requested condition (a self-checked Prowl hook or live
  exact/high transcript watcher), only layer 0–2 events resolve the wait and heuristics
  merely update "last known". Without such coverage the wait resolves
  heuristically once the state has been stable for `stable-for` (3 s hold + 2 s) and says
  so.
- Response: `{status, raw_state, source, confidence, waited_ms, signals: […]}`; with
  `--include-screen N`, a stable `detection`-source screen tail and, when available, the
  059 result state — everything an orchestrating agent needs to judge a heuristic result in
  one call.
- Prowl-dispatched work uses an opaque `dispatch_id`, not timestamps, to exclude stale
  completion. S2 ships `create` issuance, required `dispatch-complete --outcome
  succeeded|failed --summary`, bounded receipt retention, and ID-only `agents wait
  --dispatch` atomically. Receipts survive pane closure but not app restart; surface
  generation is only the unpaired fallback. The finalized contract is
  [003-s2-dispatch-wait-design.md](003-s2-dispatch-wait-design.md).
- Exact matching `session-end` / `surfaceClosed` → `AGENT_GONE` (unless generic
  `--until exit`); detector `.removed` is heuristic and cannot terminalize a dispatch.
  Timeout defaults to and is capped at 600 s, returning `WAIT_TIMEOUT` with the last known
  status/source; the skill documents "re-arm on timeout". The normative transition table,
  evidence epochs, channel registry, capture defaults, cancellation transport, and payload
  shapes are frozen in [003-s2-dispatch-wait-design.md](003-s2-dispatch-wait-design.md).

### Self-check and visibility

When a Prowl-launched runtime declares a `sessionStart` hook, the launch boundary expects
the corresponding signal within a grace window; if it never arrives the pane is marked
`signals: none` (hooks did not load) instead of silently pretending. `prowl agents`
JSON gains `signals: {channels: [...], last: {...}}` per pane, where channels describe only
current-epoch observed or verified-live evidence rather than theoretical runtime support. An
Active Agents "exact" badge was considered for S3c and dropped on 2026-08-26 without
commitment; `prowl agents --json` is the surface for exact coverage.

### Judging heuristic results (skill, not code)

When `source == screen`, the orchestrating agent — not Prowl — decides: the `prowl-cli`
skill ships a rubric (finished answer + empty prompt box vs. spinner/tool output vs. a
permission or question dialog), tells the agent to use `--include-screen` and
`agents read`, and forbids destructive actions on heuristic evidence alone. 063's V2
`on_attention: ask <role>` is the declarative form of the same idea.

### Maintenance rules

- Each runtime's hook support, event → `AgentSignal.Kind` mapping, payload parsing, and
  launch-time rendering live in its adapter (`supacode/Domain/AgentRuntime/AgentRuntimeAdapter.swift`
  family) behind a `signalHooks` capability, with fixture tests for the rendered
  flag/config and for payload decoding. A CLI that changes its hook API is a one-adapter
  change plus a matrix row update.
- `research-agent-completion-signals.md` (living, this folder) records per runtime:
  mechanism, events, per-launch enablement syntax, payload fields, OSC behavior,
  transcript marker, verification method, version, date.
- CLI contracts follow 060's four layers: `prowl.cli.agents.signal.v1`,
  `prowl.cli.agents.wait.v1`, the `agents` `signals` field; schema-validated in socket
  tests; `docs/components/cli.md` and the `prowl-cli` skill updated in the same PRs.

### Delivery slicing

This section defines **what** each slice contains; **when** it ships, and how it
interleaves with 063's slices, is owned by the shared living
[release-plan.md](../063-agent-workflows/release-plan.md) (R1: S1, S2, S3 wave 1 with
063's C0/A1/A2; R2: the S5 watchdog part; R3: S4). S3 ends after wave 1: runtimes that
require global-config, dedicated-home, or project-file writes do not receive Prowl-managed
hooks.

| Slice | Depends | Contents / expectation |
| --- | --- | --- |
| **S1** | — | Signal bus state + the `ObservedAgentState` multicast observer (snapshot / changed / removed / surfaceClosed / `.signal`; first specified in 063, delivered here so it ships first) + `prowl agents signal` for `turn-ended`, `needs-input`, session, and progress events (CLI four layers, bounded detail). Layer 0 works for every runtime immediately; 063-B3 later consumes the same observer. |
| **S2** | 063-A2, S1 | One atomic paired-dispatch path: every CLI `create tab|pane --profile --prompt` appends the completion protocol and returns `dispatch_id`; cooperative `dispatch-complete --outcome succeeded|failed --summary`; 256-entry non-destructive in-memory receipts; ID-only strict `prowl agents wait --dispatch`; generic `wait --until` with automatic overflow resnapshot and honest heuristic fallback; `agents` current evidence field; `--include-screen`; skill rubric. Route B becomes usable without polling or stale completion. |
| **S3 wave 1** | S2, research matrix | Launch-scoped hook injection (adapter `signalHooks`, self-check) for tier A of the research matrix (flag/env per launch, live-verified): Claude Code `--settings`, Codex `-c notify=[…]` (native `agent-turn-complete` maps to `turn-ended`; hook trust bypass is never passed), Copilot `--plugin-dir`, Droid `--settings`, Qoder `--settings`, Pi `-e`, OMP `--hook`, OpenCode `OPENCODE_CONFIG_CONTENT`. `agents wait` becomes deterministic for Prowl-launched agents on these runtimes. This is the complete S3 hook scope, delivered as S3a–S3c in [006-s3-wave1-plan.md](006-s3-wave1-plan.md). |
| **S4** | S1 | Transcript file-watch and OSC producers — layer 2 without hooks. |
| **S5** | 063 C1 (part), S3/S4 + 063 V2 (rest) | 063's watchdog consumes exact signals (nudge on `turn-ended` without `done`, immediate attention on `needs-input`) — ships with 063-B2 (moved from D2 on 2026-08-29); later: 063 V2 observe mode (`expect.status` + `agents read` / hook `last_assistant_message`) and `on_attention: ask <role>`. Recorded in 063 amendments. |

### Verification

Unit: bus merge/ordering, confidence gating, `wait` resolution matrix (already-satisfied,
transition, removal, pane close, timeout, two concurrent waiters), hook rendering per
adapter, payload decoding, self-check degradation. Socket: `signal`/`wait` round trips and
schema. Live: one Prowl-launched Claude Code and Codex pane each — verify hook signals
arrive, `wait` resolves with `source=hook`, and a manually launched agent resolves with
`source=screen` plus screen tail.

## Alternatives & decisions

- **Layered bus rather than a smarter heuristic.** #676 shows the heuristic can be
  improved but never made authoritative for TUIs; deterministic channels exist and should
  be used where present, with honest downgrade elsewhere.
- **Judgment by the orchestrating agent, not by Prowl.** Prowl has no model access worth
  adding for this; the waiting agent already has the task context and can read the screen
  tail that `wait` returns. On-device FM classification is deferred as an experiment.
- **Hooks only through launch-scoped channels.** Mirrors 053/006's launch-scoped
  environment decision: Prowl-launched panes get Prowl hooks; user-launched agents are
  never reconfigured.
- **Separate entry from 063.** The signals are valuable without workflows, touch
  detection/adapters/CLI rather than the runner, and need their own per-runtime
  maintenance; 063 consumes them through one observer type.

## Research outcome (2026-08-22)

The per-runtime matrix lives in
[research-agent-completion-signals.md](research-agent-completion-signals.md) (all 15 CLIs
installed locally; live hook runs for claude, codex, copilot, kimi, droid, pi, omp,
opencode; partial for qodercli/qwen/amp; docs/bundle for the rest). Key conclusions:

- Eight runtimes accept a Prowl hook **per launch without touching user config**
  (tier A above) and form the complete S3 scope. Gemini, Qwen, Grok, Cline, and Kimi require
  a Prowl-owned home; Cursor Agent and Amp require project files. Prowl does not attach hooks
  for either group.
- Codex's hook system is trust-gated per command hash; per-launch `-c hooks.*` needs
  `--dangerously-bypass-hook-trust`, which Prowl will **not** pass. Codex gets the native
  `agent-turn-complete` event (mapped to `turn-ended`) through ungated `notify`; its permission prompts stay
  heuristic/transcript-based.
- Claude Code holds all hooks in interactive sessions until the workspace-trust dialog is
  accepted — the self-check grace must tolerate that, and a trust prompt is itself a
  `blocked` state worth surfacing.
- Kimi's `--config-file` replaces the whole config; per-launch hooks there would require
  Prowl to re-supply the user's provider config, so Kimi does not receive managed hooks.
- Several payloads carry `last_assistant_message` (Claude, Codex, Qoder, Qwen, Grok,
  Gemini) — a cheap result channel for 063's V2 observe mode on those runtimes.
- Terminal escapes (OSC 9/99/777/BEL, 9;4) are focus-/threshold-gated everywhere and
  therefore only a layer-2 hint, never a completion proof.

## Open questions

- Whether hook subprocesses can always reach Prowl's socket from sandboxed runtimes
  (Codex sandbox, OpenCode/Pi/OMP plugin runtimes); `PROWL_CLI_SOCKET` and the bundled
  binary path must be passed through and verified per runtime in S3.
- S3 hook self-check grace defaults (Claude's trust-dialog hold suggests a generous,
  state-aware grace rather than a fixed few seconds).
- Re-verification cadence: the matrix is versioned per row; S3 adapters need fixture tests
  that fail loudly when a CLI's hook syntax changes. Tracked as #726 (T0 attestation in R2a,
  T1 headless contract tests in R2b).

## Amendments

- Updated 2026-08-29 (#733 re-dispatch): `prowl agents dispatch <pane> --prompt -` creates a
  new pending record for an agent already running in a pane (one pending record per surface,
  idle precondition shared with `agents wait --until idle`, delivery measured as one bracketed
  paste), and `dispatch-complete` resolves the record from the caller pane instead of
  `PROWL_DISPATCH_ID` — see [014-re-dispatch.md](014-re-dispatch.md).
- Updated 2026-08-29 (#726 T0): [agent-attestation.json](agent-attestation.json) now records the
  version each tier-A runtime last passed a live sweep against (all eight from
  [011-s3c-action.md](011-s3c-action.md)); `make agent-versions` compares the installed binaries
  against it and warns on newer builds, and the research matrix's tier-A line is generated from
  the record with `make test-scripts` guarding drift. See
  [015-t0-version-attestation.md](015-t0-version-attestation.md). T1 stays in R2b.
- Updated 2026-08-29 (063 B1 kickoff): 063's `expect` activations are records in this entry's
  dispatch store (`launch` via the S2 prompted-launch path, `message` via #733's re-dispatch),
  and S5's watchdog part ships with 063-B2 instead of D2. #733 therefore lands before 063-B3.
  See [063 dsl-spec §5/§10](../063-agent-workflows/dsl-spec.md) and
  [063.006](../063-agent-workflows/006-b1-definitions.md).
- Updated 2026-08-29: shipped in v2026.8.29 with 063's R1. Two follow-ups are scheduled as
  slices in the shared [release plan](../063-agent-workflows/release-plan.md): #733
  (`prowl agents dispatch <pane> --prompt -`, one pending dispatch per surface, completion
  resolved from the caller's ancestry) in R2a, and #726 (T0 version attestation in R2a, T1
  headless contract tests in R2b before 063-D2).
- Updated 2026-08-29: idle evidence fallback after a second end-to-end pass over the
  `prowl-cli` skill — Claude's `idle_prompt` notification is no longer decoded as
  `needs-input` (it displaced the `turn-ended` level and woke `changed` waits on idle panes),
  and `auto` condition waits fall back to the stabilized detector whenever the `verified_live`
  channel holds no terminal signal for the condition (freshly launched, unprompted Profiles).
  See [013-idle-evidence-fallback.md](013-idle-evidence-fallback.md).
- Updated 2026-08-28: follow-up on CLI evidence semantics after exercising the `prowl-cli` skill
  end to end — `agents read` reports `pending` during a live turn, condition waits require
  detector corroboration for arm-time terminal signals and tolerate 10 s of agent-appearance
  latency, `agents signal` exposes `binding` plus a `signal_unbound` warning, and the docs stop
  naming the unshipped `workflow done`. See
  [012-cli-evidence-semantics.md](012-cli-evidence-semantics.md).
- Updated 2026-08-27: S3c merged (#728), completing S3 wave 1 across
  #721/#723/#725/#728. S4 and S5 remain planned.
- Updated 2026-08-26: S3b merged (#725); planned S3c for Pi, Oh My Pi, and OpenCode after a
  live re-attestation (Pi 0.84.3, OMP 18.0.6, OpenCode 1.18.23) — extensions relay native event
  names in the Claude-shaped envelope, OMP maps `session_stop`, OpenCode is non-announcing with a
  sub-agent filter, and the exact badge was dropped. See [010-s3c-plan.md](010-s3c-plan.md).
- Updated 2026-08-25: implemented S3b for Copilot, Droid, and Qoder, and corrected an S3a-era
  defect it exposed — hook cwd validation compared unresolved paths, so a runtime reporting
  `process.cwd()` (already symlink-resolved) was silently rejected. Copilot is verified live;
  Droid's channel and Qoder's launch are open items recorded in
  [009-s3b-action.md](009-s3b-action.md).
- Updated 2026-08-25: planned S3b (Copilot/Droid/Qoder) and re-attested every tier-A runtime
  locally. Measurement overturned the assumption that a Claude-shaped `PermissionRequest` means
  "needs input": Copilot and Qoder also emit it when the permission service auto-approves and no
  human is waiting, so both derive `needs-input` from `Notification` only. The same matrix
  re-verified Claude 2.1.243 against six non-interactive scenarios and found no S3a regression.
  Injection is additive for Copilot (`--plugin-dir`), last-wins for Droid (`--settings`, path
  only), and first-wins for Qoder (`--settings`, which `--setting-sources` disables outright).
  See [008-s3b-plan.md](008-s3b-plan.md).
- Updated 2026-08-24: implemented S3a's shared trusted-hook foundation plus Claude/Codex
  adapters, resolver/forwarding boundary, launch transaction, hidden ingress, warnings, and
  focused/live contract coverage. See [007-s3a-action.md](007-s3a-action.md). S3 wave 1 remains
  incomplete until S3b/S3c.
- Updated 2026-08-23: split S3 wave 1 into three merge-safe PRs: S3a foundation plus
  Claude/Codex, S3b Copilot/Droid/Qoder, and S3c Pi/OMP/OpenCode plus UI/docs/full closure.
  Detailed S3a research, implementation phases, and validation live in
  [006-s3-wave1-plan.md](006-s3-wave1-plan.md).
- Updated 2026-08-23: removed S3 wave 2. Managed hooks are limited to tier-A runtimes that
  accept per-launch flag/environment injection without configuration writes. Gemini, Qwen,
  Grok, Cline, Kimi, Cursor, and Amp remain on cooperative, transcript/process, OSC, or
  heuristic evidence; dedicated homes and project files are not hook-installation surfaces.
- Updated 2026-08-23 after S2 merged in #718: the paired dispatch and agent-wait slice is on
  `main`; S3 wave 1 is now the next R1 orchestration critical-path slice. The independent
  065-S0/K1 bundled-skills work may continue in parallel.
- Updated 2026-08-23 during S2 review: corrected explicit slice dependencies to
  063-A2 + S1 → S2 → S3 wave 1. S3 consumes S2's wait/channel/self-check infrastructure;
  A2 and S1 are transitive rather than parallel alternatives.
- Updated 2026-08-23 during S2 implementation: delivered the frozen paired dispatch,
  completion/abandonment store, strict and generic waits, generation-aware evidence,
  peer-disconnect cancellation, signal visibility, schemas, and documentation. Execution
  evidence and the validation/E2E record live in
  [004-s2-work-note.md](004-s2-work-note.md); the shipped behavior summary is
  [005-s2-action.md](005-s2-action.md).
- Updated 2026-08-23 after PR #716 initial review: froze peer-EOF cancellation, generic wait
  transition/freshness rules, per-source channel state, old-app fail-closed behavior,
  receipt eviction linearization, exact include-screen behavior, and JSON/schema boundaries;
  detector removal no longer terminalizes strict dispatch — see
  [003-s2-dispatch-wait-design.md](003-s2-dispatch-wait-design.md).
- Updated 2026-08-23 after S1 merged in #715: owner review locked S2's paired dispatch,
  receipt lifecycle, exact-versus-heuristic wait policy, CLI outcomes, trust boundary, and
  verification scope — see
  [003-s2-dispatch-wait-design.md](003-s2-dispatch-wait-design.md).
- Updated 2026-08-23 before merge: owner raised bounded signal `--detail` from 4 KiB to
  32 KiB (32768 UTF-8 bytes). The larger bound remains well below the 32 MiB socket frame and
  macOS argument budget, accommodates useful completion summaries, and preserves the rule
  that transcript/workflow-sized output uses its dedicated channels.
- Updated 2026-08-22 before S1 implementation: owner review separated runtime `turn-ended`
  from S2's cooperative `dispatch-complete`; retained bounded `--detail`; made public origin
  claimed metadata only; required explicit overflow/resnapshot; and moved the complete
  dispatch-ID issuance/receipt/wait protocol into S2 so it cannot ship half-paired. The
  implementation record is [001-action.md](001-action.md), with the authorized execution
  checklist in [002-s1-work-note.md](002-s1-work-note.md).
- Updated 2026-08-22: prerequisite 063-A2 is implemented in PR #714. Its typed synchronous
  launch boundary preserves the adapter-rendered invocation and launch-scoped surface
  environment that S3 will extend; A2 intentionally injects no hooks. With that dependency
  ready, S1 (signal bus, multicast observer, and `agents signal`) is the next R1 critical-path
  slice, followed by S2 and S3 wave 1.

- Updated 2026-09-05 (#726 T1 planning): Inventoried all eight newer-than-attested binaries and researched low-cost/BYOK routes. Proposed a zero-inference default, scoped live evidence, and explicit attestation publication in [016-t1-contract-test-plan.md](016-t1-contract-test-plan.md); repeatable operations live in [agent-contracts-runbook.md](agent-contracts-runbook.md). Implementation and inference verification remain pending.

- Updated 2026-09-05 (#726 T1a): Implemented the zero-inference entry point, strict model policy, private reports, and production configuration preflight with receipt/test-count checks; [016](016-t1-contract-test-plan.md) records validation and the [runbook](agent-contracts-runbook.md) now contains working commands. Live contracts and attestation publication remain pending.

- Updated 2026-09-05 (#726 live checks): Eight runtimes passed the production headless preparation/real bridge suite in #767, including the Codex absent-notifier fix found during execution. See [016](016-t1-contract-test-plan.md) for scoped results and remaining publication work and separate D2 interactive acceptance.

- Updated 2026-09-05 (T1 closure): Full eight-runtime verification and explicit scoped publication passed; the baseline and matrix were advanced while preserving interactive history. Release guidance now uses `verify` then `publish`. See [064.016](016-t1-contract-test-plan.md). Merge this closure, then proceed to D2; GUI E2E is outside #726 T1.

- Updated 2026-09-05 (release order): T1 #769 merged. R2b now proceeds to 063-D3 handoff/checkpoint and first built-in E2E, with 063-D2 adversarial review deferred to R3. T1 remains prerequisite to both; S4 scheduling/dependencies are unchanged.
