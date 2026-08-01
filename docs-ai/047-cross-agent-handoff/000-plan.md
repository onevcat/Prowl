# 047 — Cross-Agent Handoff: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-07-17 |
| **Primary PRs** | #554 |
| **Related** | [042-project-workspaces](../042-project-workspaces/000-plan.md), [013-prowl-cli](../013-prowl-cli/000-plan.md), [045-native-agent-session-detection](../045-native-agent-session-detection/000-plan.md), `docs/components/cli.md` |

## Background

A task moving from one coding agent to another currently requires the user to manually
summarize state and start a receiving session. Issue #550 proposes a durable, local artifact
at a runnable target's `.prowl/handoff/` so the outgoing agent owns the semantic summary
while Prowl records mechanical repository and terminal state, then launches a receiving
agent in a new tab.

PR #554 implements the first end-to-end flow but was based on the pre-merge main branch and
now conflicts with current CLI handles, session detection, and the curated `docs-ai/`
migration. Its first transcript resolver also independently scanned Claude/Codex storage by
cwd, which is weaker than the pid-anchored, ambiguity-safe native session identity shipped in
#556.

## Goals

- Rebase the #554 handoff feature onto current `main` without regressing short CLI handles,
  `prowl agents` session metadata, or current documentation.
- Support `prowl handoff save`, `status`, and `to <agent>` for runnable workspace,
  repository/worktree, and plain-folder targets; preserve the documented positional target.
- Keep agent-authored `current.md` immutable after one-time scaffolding; write generated
  context, session excerpts, and log entries separately under `.prowl/handoff/`.
- Make `to` save then archive before creating a new receiving tab. Only proven Claude Code
  and Codex launch adapters may launch interactively; other recognized agents require
  `--no-launch`.
- Reuse the native `AgentSession` already attached to the selected pane by #556 for handoff
  metadata. Never substitute a cwd/newest-file guess when session resolution is absent or
  ambiguous.
- Auto-save only already-initialized artifacts after a detected agent transitions from
  working to done or blocked, with per-pane throttling.

### Non-goals

- Committing, pushing, changing git state, or approving a blocked agent action.
- Automatic session resume/fork beyond the narrow source-summary operation planned in
  [047.002](002-resume-authored-handoff.md), transcript parsing, or a cooperative agent hook protocol.
- Reliable retrieval of an agent's final response; that remains the separate, opt-in native
  integration proposed by #473.
- Editable workspace membership, tracked separately by #535.

## Design / Approach

- Add the `HandoffStore`, payloads, command parser/handler, router case, and text renderer.
  The store atomically writes `context.md`, writes bounded terminal excerpts to `sessions/`,
  keeps `.prowl/handoff/` locally ignored, and archives a read-only combined snapshot.
- Thread a captured `HandoffStore.SessionContext` from the selected terminal surface through
  `TerminalClient` to the CLI handler, palette action, and auto-save effect. Populate agent,
  session id, transcript path, source, and confidence from `PaneAgentState.session`; retain a
  terminal excerpt only as supplementary context.
- Resolve target and launched pane identity through the shared `TargetResolver`; preserve
  type-prefixed short handles in current `list`/`agents` text paths while adding only the
  `pane.agent` field needed by handoff orchestration.
- Add palette actions for all runnable targets and use the same artifact-first sequence as
  the CLI. The receiving tab remains selected after a successful handoff.
- Merge docs into the current `docs/` manual, replace the pre-migration design note
  with this record, and add a current handoff guide.
- Cover parser behavior, store concurrency boundaries, handler responses, reducer/palette
  visibility and auto-save gating, session-context propagation, and CLI socket rendering.

## Alternatives & decisions

- **Use #556 session state, not a handoff-local storage scan.** The shared resolver is
  pid-anchored and deliberately returns no result for ambiguity; duplicating a simpler
  Claude/Codex cwd scan could attach another pane's transcript.
- **Separate generated context from semantic notes.** Rewriting marked sections in one file
  can race an editor or agent write. `current.md` is agent-owned after atomic initial
  creation; Prowl replaces only `context.md`.
- **Local artifact rather than a Prowl-global database.** The target root follows the task
  across workspaces and stays inspectable by both agents without cloud or account setup.
- **Launch only verified adapters.** Detection recognizes more agents than Prowl can safely
  start with a correct kickoff command. `--no-launch` preserves artifact interoperability
  without pretending an unsupported launch contract exists.

## Amendments

- Updated 2026-07-18: plan resume-authored semantic preparation before `handoff to`; this supersedes
  the first wave's blanket resume exclusion — see [002-resume-authored-handoff](002-resume-authored-handoff.md).
- Updated 2026-07-20: audited the plan against the implementation and converged the
  entry points before UI work — shared `HandoffCoordinator`, one `handoffSourceContext`
  capture, registry-driven palette targets, `qodercli` catalog parity — see
  [003-plan-calibration](003-plan-calibration.md).
- Updated 2026-07-20: `current.md` adopted **snapshot semantics** — each
  preparation rewrites it entirely from the source session's own knowledge,
  superseding 047.002's "reply with the complete updated document /
  carry forward still-relevant notes" instruction. Carry-forward degraded
  into unverified copying (the source has no real memory of earlier rounds'
  text) and let stale sections mislead the receiver; history flows through
  the receiver's takeover read and the `archive/` chain instead. Decision
  record: [049 amendments](../049-agents-toolbar-entry/000-plan.md#amendments).
- Updated 2026-07-21: inline-first redesign — caller-pane source identity, inline
  `--brief` as the primary briefing path (UI injects the request into the live
  agent), side-effect-free resume-fork (`--fork-session`/`--ephemeral`) demoted to
  explicit fallback, pure archive-first transition with template/manual-maintenance
  abolished, headless launch + completion notification, `status`/auto-save removed —
  see [004-inline-handoff-redesign](004-inline-handoff-redesign.md).
- Updated 2026-07-21: HUD request ownership — injected requests now need an
  atomic single-transition claim, and fallback cancellation needs a visible commit
  boundary — see [005-hud-request-ownership](005-hud-request-ownership.md).
- Updated 2026-08-01: planned Profile-aware receiving targets with UUID-bound HUD/CLI requests,
  execution-time Profile resolution, and one shared background launch path — see
  [053.007 profile-aware handoff](../053-agent-profiles/007-profile-aware-handoff.md).
