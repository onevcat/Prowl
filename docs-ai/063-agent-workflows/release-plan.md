> **2026-09-07 naming slice:** Action bundles (#774) and personal history (#775) are
> merged. Normalize the unreleased contract before D3; see [019](019-workflow-naming.md).
> This slice does not implement handoff or adversarial review and does not publish a release.

> **2026-09-06 action bundle implementation:** Workflow UI is enabled by default in this
> change. `PROWL_WORKFLOW_UI=0` remains available to hide it. The earlier intervening-release
> opt-in gate below is historical; see [017](017-action-bundle-implementation.md).

# Agent Workflows (063) + Agent Completion Signals (064) — release plan (living)

> Living document: the single place that says **when** and **in what order** the slices of
> [063](000-plan.md) and [064](../064-agent-completion-signals/000-plan.md) ship. The
> slices themselves — what each PR contains — are defined in the owning plan's
> "Delivery slicing" section. Update this file when scope moves between releases.

> **Next public release (owner decision, 2026-09-05):** ship the merged Agent Island,
> Pi/OMP/Copilot detection fixes, terminal-close protection, and other accepted changes.
> Workflow UI is off unless Prowl starts with `PROWL_WORKFLOW_UI=1`; CLI/runtime capabilities
> remain available. Action bundles, D3 handoff migration, and D2 adversarial review are deferred
> and are not gates for this release. The [UI gate](016-workflow-ui-release-gate.md) is the final
> planned implementation PR before release preparation. The R2b/R3 tables below describe the
> deferred workflow roadmap, not the scope of this intervening release.

## Ownership

| Prefix | Owner | Meaning |
| --- | --- | --- |
| A | 063 | terminal / CLI primitives (`create pane`, profile launch boundary) |
| B | 063 | workflow definitions and runner |
| C | 063 | UI (Settings IA, status center, start sheet, entry points) |
| D | 063 | built-ins, skills, docs, handoff migration |
| S | 064 | completion signals (bus, `agents signal` / `agents wait`, hooks, producers) |

GitHub issues scheduled as slices (#733 re-dispatch, #726 drift guard) keep their issue number
as the slice name; both belong to 064.

Cross-entry couplings (only these two): 064-S1 delivers the `ObservedAgentState` observer
that 063-B3 consumes; 064-S3 attaches launch-scoped hooks through 063-A2's launch boundary.
063 V1 does not otherwise depend on 064 (steps complete on `prowl workflow deliver`).

## Releases

PRs merge to `main` one at a time (each keeps `main` shippable); engine PRs without a
user-facing surface may merge before "their" release and stay dormant. Four releases — R1,
R2a, R2b, R3 (R2 was split on 2026-08-29); the [cadence rules](#cadence-and-working-rules)
say when each is cut:

### Status (2026-09-05)

| Release | State | Next action |
| --- | --- | --- |
| R1 | **Shipped** — v2026.8.29 (2026-08-29) | — |
| R2a | **Shipped** — v2026.8.31 (2026-08-31) | — |
| R2b | In progress — C2 and D1, including Settings refinement, merged (#752/#754/#761/#763) | #726 T1a inventory/configuration preflight implemented; eight-runtime headless checks verified; T1 merged (#767/#769); D3 handoff migration and E2E next, then assess R2b release |
| R3 | Planned | D2 adversarial review after R2b ships; S4 remains independently planned |

#### R2b PR ledger

| Slice(s) | State | PR / next action |
| --- | --- | --- |
| C2 | Merged | #752: start sheet + capsule popover / palette / Active Agents entry points; [063.011](011-c2-start-sheet.md) |
| D1 (skill) | Merged | #754: `prowl-workflow` bundled authoring skill (shipped ahead of the rest of D1) |
| D1 (rest) | Merged | #761: Settings › Agents › Workflows page, `docs/components/workflows.md`, CLI reachability status (deferred from C0); [063.013](013-d1-workflows-settings.md) |
| D1 (UI refinement) | Merged | #763: post-merge native list/detail refinement, repository-local workflow Settings, Run Setup copy, explicit run targets, file opening, and capsule YAML icons; [063.014](014-workflow-settings-ui-refinement.md) |
| #726 T1 | Implemented and verified — #767 merged; closure [#769](https://github.com/onevcat/Prowl/pull/769) merged | [064.016](../064-agent-completion-signals/016-t1-contract-test-plan.md): zero-inference inventory and production configuration preflight verified; [runbook](../064-agent-completion-signals/agent-contracts-runbook.md). Eight-runtime headless checks pass; T1 verification and scoped publication are complete; R2b GUI/workflow acceptance belongs to D3. |
| D3 | Next | `prowl.handoff` and `prowl.handoff-checkpoint`, legacy retirement, first built-in workflow E2E; R2b release candidate after acceptance |
| D2 | Deferred to R3 | `prowl.adversarial-review` built-in + reviewer skill + loop-specific E2E — after the handoff-first R2b release |

#### R1 PR ledger

| Slice(s) | State | PR / next action |
| --- | --- | --- |
| C0 | Merged | #709 |
| A1 | Merged | #710 |
| A1b | Merged | #713 |
| A2 | Merged | #714 |
| S1 | Merged | #715: bus, multicast observer, `agents signal` |
| S2 | Merged | #718: paired dispatch receipt, strict ID wait, generic evidence wait; [action record](../064-agent-completion-signals/005-s2-action.md) |
| S3 wave 1 | Complete | Merged in #721/#723/#725/#728; S3c plan [064.010](../064-agent-completion-signals/010-s3c-plan.md), record [064.011](../064-agent-completion-signals/011-s3c-action.md) |
| 065-S0/K1 | Merged | #729; [065.003](../065-bundled-agent-skills/003-k1-bundle-registry.md) |
| 065-K2 | Merged | #730; [065.004](../065-bundled-agent-skills/004-k2-skill-installer-cli.md) |
| 065-K3 | Merged | #731; [065.005](../065-bundled-agent-skills/005-k3-settings-agent-skills.md); closes 065 |
| R1 tail | Merged | #732: `agents read` reports `pending` during a live turn, arm-time terminal signals need detector corroboration, 10 s agent-appearance grace, `agents signal` receipts carry `binding`; [064.012](../064-agent-completion-signals/012-cli-evidence-semantics.md) |
| R1 tail | Merged | #735: Settings › Agents › Command Line Tool renamed **CLI & Skills** (records written before it keep the old name) |
| R1 tail | Merged | #736: Claude `idle_prompt` no longer decodes as `needs-input`; `auto` waits fall back to the detector while the channel holds no terminal level; [064.013](../064-agent-completion-signals/013-idle-evidence-fallback.md) |
| Release | Shipped | v2026.8.29 — the CHANGELOG entry covers every row above |

R1 is complete and shipped. Every planned slice merged in order; the three "R1 tail" PRs
were not in the plan — each came out of driving the bundled `prowl-cli` skill end to end
against a build of `main` after the last planned slice merged, which is why that pass is now
a standing rule (see [cadence](#cadence-and-working-rules)). Scope removed during R1: S3
wave 2 (2026-08-23), the Active Agents exact-channel badge (2026-08-26), and a Profile-free
`create tab|pane --background` (recorded in 064.013 as a product follow-up, unscheduled).

#### S3 wave 1 PR breakdown

S3 wave 1 is one complete R1 release slice that landed as three sequential, independently
reviewable PR scopes:

| PR | Runtime scope | Foundation / closure scope | Depends |
| --- | --- | --- | --- |
| **S3a** | Claude Code, Codex | Trusted launch-channel registration, native-hook ingress, payload normalization, self-check/channel lifecycle, bundled hook-resource boundary | S2 |
| **S3b** | Copilot, Droid, Qoder | Plugin/settings adapters and fixtures on the S3a foundation | S3a |
| **S3c** | Pi, OMP, OpenCode | Extension/plugin adapters, complete docs and tier-A live verification (the exact-channel badge was dropped on 2026-08-26) | S3b |

The detailed implementation and verification plan starts in
[064.006](../064-agent-completion-signals/006-s3-wave1-plan.md).

### R1 — CLI orchestration primitives + completion signals

| Order | Slice | Entry | Depends | Outcome |
| --- | --- | --- | --- | --- |
| 1 | **C0** Settings IA: `Section("Agents")` with Profiles (renamed) + Command Line Tool (from Advanced); no Workflows page yet | 063 | — | CLI install lives with Agents |
| 1 | **A1** `prowl create pane` (#699) + anchored split primitive | 063 | 060 | CLI can split |
| 1 | **A1b** `PROWL_PANE_ID` per-pane environment variable (joins `PROWL_WORKTREE_PATH` / `PROWL_ROOT_PATH`) + `prowl-cli` skill self-identification rewrite | 063 | A1 | agents address their own pane deterministically (`--pane "$PROWL_PANE_ID"`) instead of guessing from `focused` |
| 1 | **065-S0/K1** skill-target spike; `embed-skills` + `ProwlSkills` registry | 065 | — | skills ship in the bundle; D1 prerequisite |
| 2 | **A2** profile launch boundary + `create tab\|pane --profile <p> --prompt -` + `profiles list` | 063 | A1 | CLI launches a profile with a kickoff prompt and gets the pane back |
| 2 | **S1** signal bus + `ObservedAgentState` multicast observer + `prowl agents signal` (`turn-ended`, needs-input/session/progress, bounded detail) | 064 | — | layer-0 signals for every runtime |
| 2 | **065-K2** shared `SymlinkInstaller` + `prowl skills list\|install\|uninstall\|path` | 065 | 065-K1 | one command installs Prowl's skills into agent skill folders |
| 3 | **S2** prompted-profile dispatch pairing (`create` dispatch ID, required `dispatch-complete --outcome ... --summary`, 256-entry receipt retention, strict ID-only `agents wait --dispatch`) + generic evidence wait, `source`/`confidence`, `--include-screen`, live `agents.signals`, and skill rubric | 064 | A2, S1 | no hand-written polling or stale completion; deterministic task receipts stay separate from labelled heuristics |
| 3 | **065-K3** Agent Skills section on Settings › Command Line Tool | 065 | 065-K2 | GUI users install skills without a terminal |
| 4 | **S3 wave 1** launch-scoped hooks for tier-A runtimes (Claude Code, Codex `notify`, Copilot, Droid, Qoder, Pi, OMP, OpenCode) + self-check | 064 | S2 | `agents wait` is deterministic for Prowl-launched agents |

User-visible result: onevcat's daily CLI-driven orchestration is first-class
(`create pane --profile --prompt -` → `agents wait` → `send`). Docs: `docs/components/cli.md`,
`agent-detection.md`, `settings.md`, `prowl-cli` skill. Parallelism: C0 ∥ A1 ∥ 065-K1, A2 ∥ S1.

### R2a — Workflow engine and CLI

| Order | Slice | Entry | Depends | Outcome |
| --- | --- | --- | --- | --- |
| 1 | **B1** definitions (Yams, model, validator, JSON Schema, three-source discovery, `workflow list/validate/schema`) — #740, record [063.006](006-b1-definitions.md) | 063 | — | DSL authorable and validatable; dormant until B3 |
| 1 | **#733** `prowl agents dispatch <pane> --prompt -`: a new pending dispatch bound to an existing surface, one pending per surface, `dispatch-complete` resolved from the caller's ancestry to the pane's current record, refused while the agent is working or blocked | 064 | S2, 064.012 | a reviewer launched once takes N assignments, each with its own receipt — the transport B3's `message` + `expect` rides on (decision 2026-08-29), and usable from the CLI recipe as soon as it merges |
| 1 | **#726 T0** version attestation: per-runtime attested version record beside the research matrix + `make agent-versions` | 064 | S3 wave 1 | an installed runtime newer than its attested contract warns before a release |
| 2 | **B2** runner core (pure state machine, run store, templates, registry, watchdog) — record [063.007](007-b2-runner-core.md) | 063 | B1 | watchdog on exact signals (064-S5 watchdog part, moved from D2); dormant until B3 |
| 3 | **B3** runner wiring + `workflow run/status/deliver/cancel` | 063 | A2, S1, B2, #733 | engine powered on |
| 4 | **C1** status center + run panel + notifications | 063 | B3 | runs visible |

User-visible result: a workflow file runs from the CLI (`prowl workflow run`), its steps and
attention states show in the status center, and a coordinating agent can re-dispatch into a
reviewer it already launched. **R2a is released only after both B3 and C1 merge**: B3 intentionally
leaves attention controls to C1, so a non-strict provisional delivery must never ship as a
cancel-only production workflow state. Parallelism: B1 ∥ #733 ∥ #726 T0 (the two 064 slices do not
touch B1's files); #733 must merge before B3 starts. Docs: `workflows.md` (CLI part), `cli.md`, `prowl-cli` skill.

### R2b — Workflow GUI, docs, and the first built-in

| Order | Slice | Entry | Depends | Outcome |
| --- | --- | --- | --- | --- |
| 1 | **C2** start sheet + entry points (capsule popover, palette, Active Agents) | 063 | B3 | GUI-initiated runs |
| 2 | **D1** `prowl-workflow` authoring skill (shipped early in #754; skills embedding from 065), `docs/components/workflows.md`, Settings › Workflows page, CLI reachability status (deferred from C0) | 063 | B1, C2, 065-K1 | custom workflows, agent-assisted authoring |
| 3 | **#726 T1** headless contract tests against the real tier-A binaries through the production renderers/decoder (`make test-agent-contracts`, passing runs update T0) | 064 | #726 T0, S3 wave 1 | hook contracts fail loudly on binary drift before D3's E2E leans on them |
| 4 | **D3** `prowl.handoff` + `prowl.handoff-checkpoint`, native actions, legacy retirement, docs/skill migration, and Debug E2E | 063 | A2, C2, D1, S3 wave 1, #733, #726 T1 | handoff is the first built-in workflow; assess R2b release after acceptance |

The owner revised the order on 2026-09-05: handoff is simpler than adversarial review and
will provide the first built-in workflow validation. Keep slice IDs stable (D3 remains handoff,
D2 remains adversarial review); their numbers no longer imply execution order. This supersedes
the earlier requirement to leave handoff untouched through R2b and D3's dependency on D2.

R2b becomes eligible for release after D3 acceptance, without waiting for D2:

- Both handoff and checkpoint work through the workflow entry points, including briefing,
  context-only, self-initiated delivery, and receiver launch where applicable. Preserve the
  `.prowl/handoff/` archive/current/context semantics and cover failure/cancel paths.
- Drive the bundled workflow skill and GUI through a Debug app. Verify admission/attribution,
  permission/attention handling, delivery, and applicable watchdog behavior. T1 headless
  evidence alone cannot satisfy this first built-in E2E gate.
- Replace the dedicated handoff HUD/execution path; update docs and skills. The old CLI remains
  a non-executing `HANDOFF_RETIRED` stub with replacement commands for one release, not a
  warning-and-forward compatibility adapter.
- Complete the normal full T1 verify/publication and release checks. Acceptance permits a
  release decision; it does not automatically publish or waive unresolved failures.

### R3 — Adversarial review + signal completion

| Order | Slice | Entry | Depends | Outcome |
| --- | --- | --- | --- | --- |
| 1 | **D2** `prowl.adversarial-review` built-in + reviewer skill + loop/verdict/watchdog E2E | 063 | D3 accepted and R2b shipped; A2, C2, D1, S3 wave 1, #733, #726 T1 | review workflow builds on the validated handoff workflow path |
| 1 | **S4** transcript file-watch + OSC producers | 064 | S1 | layer-2 signals without hooks |

There is no S3 wave 2. Runtimes that require writes to a global config, dedicated home, or
project file do not receive Prowl-managed hooks. S4's scope and independent dependency are
unchanged. Delete the `HANDOFF_RETIRED` stubs one release after their R2b introduction
(expected R3), rather than one release after the former R3 handoff slot.

### R3+ — V2

063 V2 items (observe mode, `on_attention: ask <role>`, fan-out, retention, run resume,
cross-worktree roles, GUI editor) and the rest of 064-S5; scheduled by demand.

## Cadence and working rules

Agreed 2026-08-29 after R1 shipped; they apply from R2a on.

- **Ship when a coherent slice set is on `main`, not on a calendar.** R1's tags landed 4–9
  days apart. A release is cut when the slices in its table are merged and the end-to-end
  pass below is green; a slice that is not ready moves to the next release in this file
  rather than holding the current one.
- **One PR at a time, each keeping `main` shippable.** Engine slices without a user-facing
  surface (B1, B2) merge early and stay dormant; the release table lists them where they
  become visible.
- **Every merged slice is driven end to end from the bundled skill** (`prowl-cli`, and from
  B3 the workflow recipe as well) against a Debug build of `main` before the next slice
  starts. R1's tail (#732, #736) came entirely from such passes; unit and socket tests alone
  do not close a slice. Isolated-instance recipes: 064.007 / 009 / 011 / 013.
- **Grill before a public surface.** A slice that introduces a public contract — B1's DSL,
  JSON Schema, and `workflow` CLI; C2's start sheet; D1's skill and Settings page — gets a
  `grill-me` pass on its slice record before code, and the DSL spec is amended in the same
  PR when a decision changes it.
- **Drift guard travels with the release.** #726 T0 (`make agent-versions`) ships in R2a and
  runs before every release from then on; T1 (`make test-agent-contracts`) ships in R2b
  before D3's first built-in E2E and is re-run whenever a runtime is upgraded or a release is cut.
- **Records move with the code.** The PR that merges a slice updates this file's ledger and
  change log, the owning plan's Status / Primary PRs lines and Amendments, and the slice's
  own record; the release PR adds the "shipped" line. A stale ledger is a defect of the next
  PR, not of a later audit.
- **Release mechanics** stay with the
  [release runbook](../001-fork-bootstrap-and-release-pipeline/release-runbook.md)
  (`sync-docs`, CHANGELOG, notarized build); nothing here changes them.

## Dependency graph

```
R1:  C0            A1 ──► A1b                         (shipped v2026.8.29)
                     └──► A2 ──┐
                               ├──► S2 ──► S3w1 ──► #732 ──► #736
                          S1 ──┘
     065-S0/K1 ──► 065-K2 ──► 065-K3
R2a: B1 ──► B2 ──► B3 (◄ A2, S1, #733) ──► C1
     #733 (◄ S2)        #726-T0 (◄ S3w1)
R2b: C2 (◄ B3) ──► D1 (◄ B1, 065-K1) ──► D3 (◄ S3w1, #733, #726-T1)
     #726-T1 (◄ #726-T0)
R3:  D2 (◄ D3 / R2b shipped)        S4 (◄ S1); delete HANDOFF_RETIRED stubs
R3+: V2 / S5 rest
```

## Change log

- 2026-09-05 — Implemented #726 T1a: `make test-agent-contracts` now provides zero-inference inventory, secret-free model policy, private reports, and a production configuration preflight with nonce/test-count evidence. Live contracts remain pending. The release skill/runbook surface this distinction before bump/tag; [064.016](../064-agent-completion-signals/016-t1-contract-test-plan.md).

- 2026-09-05 — Confirmed #763 merged and corrected the stale D1 status. Inventoried all eight installed tier-A runtimes (all newer than T0), researched low-cost/BYOK routes, and proposed T1's repeatable probe and evidence boundaries in [064.016](../064-agent-completion-signals/016-t1-contract-test-plan.md). Implementation and inference verification remain pending; T1 still precedes D2.

- 2026-09-05 — Implemented and verified the grilled D1 Settings refinement (#763): compact global/repository lists, shared reducer-owned detail navigation, explicit Run targets through existing admission, repository-qualified preference migration, direct YAML opening, YAML icons and exact-detail routing from the Agents capsule, and synchronized user docs. `make check`, the full app test suite, Debug build, and Normal/Shelf/Canvas visual gates passed. Result: [063.014](014-workflow-settings-ui-refinement.md).
- 2026-09-04 — After #761 merged, owner review and an `impeccable`/native-macOS design pass found the Workflows root rows too dense and the repository placement misleading. The grilled refinement makes the root a minimal list, pushes configuration into a shared detail, places repository workflows directly in each repository's Settings, clarifies Run Setup and role preferences, makes run targets explicit, opens YAML directly, repository-qualifies local preferences, and carries YAML icons into the Agents capsule. Plan: [063.014](014-workflow-settings-ui-refinement.md).
- 2026-09-04 — D1 (rest) started on `feat/workflow-settings-d1` after the C2 (#752) and D1-skill
  (#754) rows were entered in the ledger above (both merges had left the Status table at
  "C2 starts next"). Scope and decisions: [063.013](013-d1-workflows-settings.md).
- 2026-09-04 — The D1 authoring skill shipped ahead of the rest of D1 as `prowl-workflow`
  (#754; singular, matching `prowl workflow …` and `prowl-cli` — the plan's `prowl-workflows`
  name is superseded). Before merge it was driven end to end from fresh agents that saw only
  the skill and the CLI: one ran an existing demo workflow, one authored and ran a new
  two-agent workflow (validated first try, `close:` steps included), and a launched participant
  loaded the skill from the typed `[Prowl] …` line. That pass surfaced the `iteration_limit_reached`
  trap (a loop is only left through a satisfied `until`; the "poor-man's if" is not an `if`),
  now spelled out in the skill with a gave-up-verdict pattern. D1's remaining scope (Settings ›
  Workflows page, `docs/components/workflows.md`, CLI reachability) is unchanged.
- 2026-08-31 — R2a shipped in v2026.8.31: B1 #740, #733 #741, #726 T0 #739, B2 #743, B3 #744, C1 #747.
  The release also carried the display-sleep fix #746 and two external contributions (#748
  blocked-agent sidebar indicator, #749 fixture `--agent` validation). `make agent-versions` ran
  before the release and warned that six tier-A runtimes are newer than their attested contracts
  (claude 2.1.251, codex 0.151.0, droid 0.204.0, qodercli 1.1.31, omp 18.0.10, opencode 1.18.25);
  #726 T1 (R2b) verifies them. The release notes frame workflows as an early preview until the
  R2b UI ships.
- 2026-08-29 — B2 implemented on `feat/workflow-runner-core-b2` and opened as #743 after a grill session that
  settled the runner shape (pure reducer + effects, token check in the machine, per-activation
  watchdog streams, `run.json` v1 without tokens, Relaunch for launch roles only, immediate Skip
  consequence, pure binding resolver); the DSL spec was clarified in the same PR. Record:
  [063.007](007-b2-runner-core.md). B1 (#740), #733 (#741), and #726 T0 (#739) merged before it;
  B3 is next.
- 2026-08-29 — B1 kickoff: the DSL spec was aligned with the shipped dispatch model (grilled
  decisions in [063.006](006-b1-definitions.md)). #733 becomes a hard prerequisite of B3
  (activations ride on re-dispatch), and 064-S5's watchdog part moves from D2 into B2 so the
  runner never ships a heuristic-only watchdog. Order inside R2a is unchanged.
- 2026-08-29 — R1 shipped in v2026.8.29 (tag `5ba8aacd`), including three unplanned tail PRs
  found by end-to-end passes over the `prowl-cli` skill: #732 (064.012 evidence semantics),
  #735 (Settings page renamed CLI & Skills), #736 (064.013 idle evidence fallback). R2 is
  split into R2a (B1–C1) and R2b (C2–D2); #733 re-dispatch and #726 T0 attestation join R2a
  as D2 prerequisites, #726 T1 precedes D2 in R2b. Added the cadence and working rules.
- 2026-08-28 — 065-K3 implemented on `feat/bundled-skills-k3` and opened as #731: the Agent
  Skills section on Settings › Agents › Command Line Tool; 065's action log
  ([065.001](../065-bundled-agent-skills/001-action.md)) summarizes K1–K3. Record:
  [065.005](../065-bundled-agent-skills/005-k3-settings-agent-skills.md).
- 2026-08-28 — 065-K2 merged in #730 after four review rounds and a real-environment check.
  K3 (Agent Skills section on Settings › Command Line Tool) started on
  `feat/bundled-skills-k3`; it is the last 065 slice and the last open R1 item.
- 2026-08-27 — 065-K1 merged in #729. K2 (shared `SymlinkInstaller` + `prowl skills`) was
  implemented on `feat/bundled-skills-k2` and opened as #730; K3 remains planned inside R1.
  Record: [065.004](../065-bundled-agent-skills/004-k2-skill-installer-cli.md).
- 2026-08-27 — 065-S0 completed its target verification and K1 implemented the bundled-skill
  foundation; K2/K3 remain in R1. Record: [065.003](../065-bundled-agent-skills/003-k1-bundle-registry.md).
- 2026-08-27 — S3c merged (#728), completing S3 wave 1 across #721/#723/#725/#728.
  The remaining R1 work is 065 bundled skill distribution.
- 2026-08-26 — S3b merged (#725). S3c started on `feat/agent-signal-hooks-s3c` after a
  live re-attestation of Pi 0.84.3, Oh My Pi 18.0.6, and OpenCode 1.18.23; the Active Agents
  exact-channel badge was removed from S3c without commitment. Plan:
  [064.010](../064-agent-completion-signals/010-s3c-plan.md).
- 2026-08-25 — S3a merged (#721 plus post-merge hardening #723) and S3b started on
  `feat/agent-signal-hooks-s3b`. A local re-attestation of all tier-A runtimes showed that
  Copilot and Qoder emit `PermissionRequest` even when the permission service auto-approves,
  so those two derive `needs-input` from `Notification` only; the same matrix confirmed Claude
  2.1.243 does not, leaving S3a correct as shipped. Plan: [064.008](../064-agent-completion-signals/008-s3b-plan.md).
- 2026-08-24 — S3a implemented the trusted launch registration/epoch boundary, hidden native
  ingress, Claude settings merge, Codex effective-notifier preservation, degradation warnings,
  and focused/live contract coverage. S3 wave 1 remains incomplete pending S3b/S3c.
- 2026-08-23 — S3 wave 2 was removed. Prowl ships launch-scoped hooks only for tier-A
  runtimes that need no global-config, dedicated-home, or project-file writes; Gemini,
  Qwen, Grok, Cline, Kimi, Cursor, and Amp remain on non-hook evidence layers.
- 2026-08-23 — S2 merged in #718 after full gates, authenticated Claude/Codex dispatch E2E,
  and two adversarial review rounds. The next R1 orchestration critical-path slice is S3
  wave 1; 065-S0/K1 remains independent parallel work.
- 2026-08-23 — S2 review corrected the explicit critical path to A2 + S1 → S2 → S3 wave 1;
  S3 consumes the wait/channel/self-check infrastructure delivered by S2 rather than branching
  directly from its two transitive prerequisites.
- 2026-08-23 — S2 implemented on `feat/agent-dispatch-wait-s2`: prompted Profile dispatch
  pairing, immutable receipts, completion/abandonment, strict and generic waits,
  generation-aware evidence, stable screen evidence, peer-EOF cancellation, and live
  `agents.signals`. All gates and isolated Debug E2E completed; draft PR #718 opened.
- 2026-08-23 — S1 merged in #715. Owner review then locked S2: prompted launches always
  create a dispatch, completion has an immutable succeeded/failed summary receipt, strict
  dispatch waits never accept heuristic completion, and generic waits retain honest auto
  fallback. See [064.003](../064-agent-completion-signals/003-s2-dispatch-wait-design.md).
- 2026-08-22 — S1 started on `feat/agent-completion-signal-bus`; owner review moved the
  complete dispatch-ID issuance/receipt/wait protocol into S2, renamed the runtime edge to
  `turn-ended`, retained bounded detail, and required explicit overflow resnapshot.
- 2026-08-22 — A2 merged in #714 after C0 #709, A1 #710, and A1b #713. The next R1
  critical path is 064-S1 → S2 → S3 wave 1; 065-S0/K1 remains independent parallel work.
- 2026-08-22 — A1 review: added **A1b** (`PROWL_PANE_ID`) to R1; `create pane` keeps an explicit
  anchor (no caller-pane default) and a background placement stays with A2.
- 2026-08-22 — first version: three releases agreed; `ObservedAgentState` observer moved
  from 063-B3 to 064-S1; C0 ships without the Workflows page; `prowl agents wait` owned by
  064-S2.
- 2026-08-22 — 065 bundled-agent-skills joins R1 (S0/K1 ∥ A1, then K2, K3); `embed-skills`
  and the skill registry move from 063-D1 to 065-K1, D1 depends on it.

- 2026-09-05 — Continued #726 in #767: all eight real headless runtime/hook checks passed; seven use the owner's DeepSeek key and Qoder uses its existing Flash catalog route. Fixed absent-notifier configuration reads found by the suite. Release preparation now points at implemented live/preflight commands. Scoped attestation publication remained before T1 closure; interactive acceptance belongs to D2; D2 remains separate.

- Updated 2026-09-05 (T1 closure): Full eight-runtime verification and explicit scoped publication passed; the baseline and matrix were advanced while preserving interactive history. Release guidance now uses `verify` then `publish`. See [064.016](../064-agent-completion-signals/016-t1-contract-test-plan.md). Merge this closure, then proceed to D2; GUI E2E is outside #726 T1.

- 2026-09-05 — Owner changed the release order: D3 handoff/checkpoint migrates in R2b and supplies the first built-in E2E; consider releasing after its acceptance. D2 adversarial review moves to R3. Keep slice IDs and CLI retirement semantics; remove stubs one release after their actual introduction. T1 #769 is merged.

- Updated 2026-09-05 (release scope): #770/#771 merged. Release the Island/detection improvements now with workflow UI opt-in; defer action bundles, handoff, and review workflow acceptance. See [016](016-workflow-ui-release-gate.md).
