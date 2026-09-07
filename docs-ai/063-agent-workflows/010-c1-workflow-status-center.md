# 063.010 — Workflow Status Center (C1)

## Status

Merged in [#747](https://github.com/onevcat/Prowl/pull/747) on 2026-08-31 after implementation,
adversarial review, and reviewed-head live verification, following B3
([#744](https://github.com/onevcat/Prowl/pull/744)). C1 closed the R2a implementation scope, and
R2a shipped the same day in v2026.8.31.

## Product contract

C1 makes the already-live B3 runner understandable and recoverable without changing how a run
starts. The toolbar's principal status item is a runtime indicator/control for the selected
worktree:

- priority stays `toast > active workflow run > pull request > palette hint`;
- the compact item shows the most recently started active run's current step, an animated running
  indicator or orange attention symbol, and an active-run count when the worktree has more than
  one run;
- hover opens the run panel temporarily; click pins it;
- the panel lists every active run in the selected worktree and shows workflow/worktree/elapsed
  state, role panes, a capped scrolling step history, repeat rounds, the current instruction,
  every machine-authorized attention action, and Cancel / Reveal Run Folder / Open Log;
- role and Focus Pane controls select the worktree and focus the exact bound pane;
- successful completion reuses the toolbar success toast. Attention and terminal run transitions
  enter the existing notification pipeline with a pane target. When the user is already viewing
  that worktree, the existing `muteNotificationsForActiveSurface` setting decides whether external
  delivery is suppressed; the sidebar notification event is still emitted.

The runner remains the authority for action availability. The presentation layer must render the
`WorkflowAttention.actions` list exhaustively and must not reconstruct recovery policy from the
attention reason.

## Decisions frozen before implementation

1. C1 is one atomic PR. Internal commits may separate tests, implementation, and review fixes.
2. R2a stays CLI-first. Runs start through `prowl workflow run` and authored YAML; the C2 start
   sheet/pickers, D1 Settings/authoring skill, and D2 built-in workflow remain later slices.
3. The run panel is only current runtime state: active and needs-attention runs, not history or a
   recent-completions surface.
4. Every currently legal recovery/termination action is a release gate. This includes Focus Pane,
   Nudge Again, Keep Waiting, Retry, Relaunch, Accept as Delivered, Accept with every declared
   verdict, Ask Again, Skip, Cancel, plus role-pane focus and run-folder/log access.
5. Skip copy shows its consequence before confirmation: either the workflow continues with an
   optional input absent, or the run ends because a named downstream step depends on the output.
6. The merged Ghostty fix in #746 is the display-sleep solution. C1 adds no headless/fail fallback
   and no `window-vsync` override; headless remains an independent V2 topic.
7. The surface inherits the native-toolbar rules in 061: one `.principal` display item, native
   controls and popover, no new Liquid Glass exception, and visual verification in Normal, Shelf,
   and Canvas at normal and constrained widths.

## Implementation shape

- Add a pure, equatable workflow status-center presentation model derived from
  `WorkflowRunsFeature.State`, selected worktree id, and the current date. It owns deterministic
  run ordering, toolbar priority inputs, role/step/round rows, current instruction copy, skip
  consequence copy, and the exhaustive attention-control mapping.
- Keep SwiftUI declarative: `ToolbarStatusView` selects the priority state; a dedicated workflow
  popover button owns hover/pin behavior; the panel renders the model and sends typed panel intents.
- Route machine actions through `WorkflowRunsFeature.Action.userAction`. Focus, reveal, and open-log
  remain presentation intents at the app/view boundary.
- Emit typed workflow status-edge delegates from `WorkflowRunsFeature`, then let `AppFeature`
  coordinate selected-worktree toast and the existing terminal notification pipeline. Edge
  comparison prevents persistence/bookkeeping events from duplicating alerts.

## Automated verification matrix

- Presentation projection: selected-worktree filtering, terminal exclusion, deterministic recency,
  multiple-run count, running/attention summary, empty/current-step fallback, roles with and without
  panes, top-level and repeated step records, full current instruction, elapsed formatting, and skip
  consequence.
- Exhaustive controls: every `WorkflowAttentionAction` maps to one usable panel intent; provisional
  verdict choices produce one action per declared verdict; unavailable focus targets are represented
  honestly; Cancel remains available outside attention.
- Reducer edges: no duplicate notice for unchanged status, attention transitions (including a changed
  attention), completed/skipped/max-rounds transitions, no completion notice for explicit cancel,
  user-action routing, selected-worktree completion toast, and foreground/background notification
  behavior.
- Existing workflow machine/reducer suites, full app tests, formatting/lint, and app build stay green.

## Review and release gate

After local self-review and the first PR push:

1. Direct a neighboring Claude agent through `prowl-cli` for at least two adversarial review rounds.
   Reviews focus on plan drift and material UX/correctness risks, avoid speculative nitpicks, and use
   the main review session rather than a fleet of subagents.
2. Verify every finding locally. Accepted fixes start with a failing regression test where the seam
   is testable, then update the PR and leave a PR comment recording disposition and evidence.
3. Continue while any P0/P1 or serious P2 remains.
4. Run the high-risk live E2E only on the reviewed PR head: happy path, provisional delivery and
   verdict acceptance/ask-again, watchdog recovery, gone-role relaunch, multiple runs/background
   notification, focus/reveal/log controls, toolbar width/mode/accessibility checks, and a display-
   sleep launch smoke. Any live-path fix gets another adversarial review before merge readiness.

## Non-goals

- GUI workflow start/binding selection, workflow authoring or Settings management.
- Built-in workflows or migration of the shipped handoff.
- Workflow history, restart resume, retention, headless execution, or new DSL semantics.
- A second status item, custom toolbar glass, or changes to the existing PR/status priorities beyond
  inserting the active workflow state at the planned position.

## Delivery, review, and live verification

### Implementation and cheap gates

- The toolbar priority projection, run/role/step/round presentation, exhaustive attention-control
  mapping, skip consequence, status-edge notices, selected-worktree completion toast, terminal
  notification routing, and the native run panel are implemented.
- `make check`: passed (format, strict SwiftFormat, strict SwiftLint, 76 repository checks).
- Focused workflow/notification regression group: 107 tests passed.
- Final `make test`: both result bundles passed; the primary bundle contained 2,915 tests and the
  secondary bundle 2 tests, with zero failures.
- `make build-app`: passed with zero errors and zero warnings.
- CLI release gates passed: `make build-cli`, `make test-cli-smoke`, 233 CLI unit tests, and 110
  CLI socket integration tests.
- `make agent-versions`: completed; `copilot`, `pi` are attested, while the installed `claude`,
  `codex`, `droid`, `qodercli`, `omp`, and `opencode` are newer than the R2a T0 ledger. This is the
  expected #726 T1 follow-up scheduled before D2, not a C1 behavior failure.

### Pre-review Debug visual verification

An isolated Debug app and CLI socket ran a real local workflow against a detected Codex pane. The
running toolbar item and pinned run panel were inspected in Normal, Shelf, and Canvas modes at the
normal window size and at macOS half-width. The current title, full instruction, role chip,
document-order steps, elapsed state, and footer controls remained legible and usable; the fixed
580-point single-run panel fit the constrained window without clipping. The workflow also completed
through `prowl workflow deliver -`, after which the active item disappeared as designed. Temporary
workflow input was removed; persisted local run records remain under the self-ignored run store.

### Adversarial review record

- A first neighboring-agent adversarial review found five material interaction/notification gaps;
  all were accepted and fixed test-first:
  - selected-worktree workflow notices now use the existing active-surface mute preference instead
    of treating selection alone as proof that the run is viewed;
  - the toolbar reports attention from any active run while retaining the newest run as the primary
    summary;
  - interacting with panel controls pins the hover-open panel so confirmation menus cannot vanish
    on pointer exit;
  - the workflow popover stays mounted while a toast overlays it, preserving pinned panel state;
  - selected-worktree `skipped` and `iterationLimitReached` outcomes now receive warning toasts, while
    successful completion keeps the success toast.
- The duplicate-edge reducer test now keeps exhaustive TestStore checking enabled through the next
  action, so an unexpected duplicate notice cannot be discarded before the assertion boundary.
- The toolbar still summarizes the newest run, but a run needing attention is now the default panel
  selection and VoiceOver label target, avoiding an extra hunt in multi-run panels.
- Round 2 independently traced all five fixes and ran 68 relevant tests plus strict SwiftLint. It
  found no P0, P1, or serious P2 and recommended merge after reviewed-head live E2E.
- Round 3 reviewed the attention/default-selection and exhaustive-test follow-up. Its two P3
  findings were accepted: closing the popover now clears sticky selection, and notification docs
  distinguish pane-level ordinary notices from worktree-level workflow notices.
- Round 4 reviewed only that final delta, found no P0/P1/P2, and approved `7c235988` as the safe
  reviewed E2E head.
- Live E2E then exposed an inert-toolbar regression after a pinned last run completed and a later
  run started in the same selected worktree. `e301696e` keeps the workflow status control mounted
  through the zero-run transition so its local popover state closes and resets reliably.
- Round 5 reviewed only that live-found fix. It found no P0/P1/material P2 and confirmed the hidden
  zero-run control is zero-size, hit-test-disabled, and Accessibility-hidden without regressing
  toast/pin identity, selection retention, worktree/mode transitions, or task cleanup.

### Reviewed-head live E2E

- With the macOS session locked, the reviewed `7c235988` Debug build launched, created a new terminal
  surface, ran a captured shell command successfully, and launched a real Codex profile. This
  directly covers the display-sleep/locked-session surface path; the later final delta only changes
  toolbar view lifetime and received its own focused review and rebuilt-app E2E.
- A real launch-role happy run completed through the generated `prowl workflow deliver -` command and
  persisted its output with verdict `clean`.
- Concurrent provisional runs exercised all delivery decisions: `Ask Again` injected the generated
  remediation prompt and accepted a corrected re-delivery; `Accept as Delivered` persisted a valid
  delivery with a missing required section; and the hover-open `Accept with Verdict` menu pinned the
  panel and persisted the selected `clean` verdict.
- Gone-role recovery replaced the dead p22 binding with a new p30 pane and resumed the step. A
  separate run exercised the destructive Cancel confirmation and finished `cancelled` while keeping
  its pane and deliveries.
- The watchdog reached attention through its real automatic nudge and idle grace. `Nudge Again`
  delivered another completion reminder, `Keep Waiting` re-armed the grace period, and the next
  attention state was actually skipped after confirming the displayed consequence.
- Hover preview opened and closed without pinning; interacting with Skip and the verdict menu pinned
  it across pointer exit and native confirmation/menu presentation. A real happy-path completion
  showed its green toolbar toast while the pinned watchdog panel remained visible and retained its
  selection, then restored the run indicator after the toast dismissed.
- Role-chip focus selected the exact bound pane. Reveal Run Folder selected the exact persisted run
  directory in Finder, and Open Log opened that run's `log.md`. The sidebar notification list showed
  background attention/completion events, and selecting the watchdog notice focused its p26 pane.
- Shelf, Default, and Canvas modes were inspected on the final build at the approximately 768-point
  constrained width. The native toolbar item and panel remained legible and unclipped. Accessibility
  exposed the attention-aware run title/count plus named recovery and footer controls.
- The live-found zero-run regression was reproduced and then retested in a fresh installed Debug
  process: pinned provisional run -> completed -> zero active runs -> toast dismissed -> new run in
  the same worktree -> the first toolbar click opened the new panel. No worktree reselection was
  required after `e301696e`.
