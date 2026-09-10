# 063.021 — Step-Based Workflow History UI

| | |
| --- | --- |
| **Status** | Implemented; UI refinement and hover switching verified in Debug |
| **Anchor date** | 2026-09-08 |
| **Related** | [Status center](010-c1-workflow-status-center.md), [history storage](018-history-storage-plan.md), [toolbar rules](../061-native-toolbar-controls/toolbar-controls.md) |

## Context and decisions

The active status panel already shows steps, rounds, roles, and attention controls. It
excludes terminal runs and closes when the last active run ends. Settings history provides
retention, export, and cleanup, but no step details. Users need to inspect execution after
completion, including runs in which their agent participated rather than initiated.

Use one generic step-based presentation for every workflow. Do not add a display DSL or
workflow-specific result layouts. Step titles, deliveries, verdicts, action outputs, and
recorded errors supply the content. Execution success and business verdicts remain distinct:
a completed review step with an `issues` verdict still receives a completion checkmark.

## Toolbar entry and scope

- Place Workflow History immediately right of Bell, before the conditional Update button.
  Reuse the isolated shared capsule in Normal, Shelf, and Canvas; follow the toolbar guide.
- Show the entry when its available scopes contain active or retained runs. Keep it after
  completion. Use a static history icon and tooltip; no cumulative count or completion badge.
- Default to **This Pane**: the union of runs initiated from the current pane and runs in
  which the current pane or its identified agent session was bound to any workflow role.
  Deduplicate by run ID. Source-only filtering is insufficient.
- Match concrete pane/session identity, never the agent executable, display name, or profile
  alone. Two unrelated agents of the same type must not share participant history.
- Offer **This Worktree** and **All Runs** for broader history, closed panes, and records
  without enough identity information. With no current pane, default to This Worktree.
- Show a short relationship label when useful: Started here or Role: reviewer. Multiple
  role matches remain one run. In broader scopes show worktree attribution.
- Hover opens a preview; click pins it. Selecting a run or interacting with a step also pins
  it. Moving the pointer from button to panel must not dismiss it. Esc/outside click closes.
- The center status entry opens the same detail surface and selects its active run.
  Workflow notices should also select their run when the record remains available.

## Panel layout and selection

Use two columns: a compact run list and a wider step detail pane. Each column scrolls
independently; header and footer stay visible. Bound panel size to the available screen.

The list puts active runs first, then history by descending time. Rows show name, a
baseline-aligned state symbol, and attribution when needed; no repeated state/time text. Initially load about ten recent records and offer
Load More. This is a presentation limit, not a retention change. First opening selects an
attention run, otherwise an active run, otherwise the latest historical run.

The detail header shows name and overall state on one line, then a clock symbol,
local `yyyy-MM-dd HH:mm` start time, and elapsed duration on one line. The
step list is the main content; do not place a large result dashboard above it. While open,
keep the selected run, expanded steps, and reading position stable across status changes,
new runs, and list reorderings. A pane/scope change must not silently replace an open detail;
keep the selected record until the user selects another run or reopens the panel.

## Step rows and details

| State | Presentation |
| --- | --- |
| Completed | Checkmark; successful execution, independent of verdict |
| Running | Small progress indicator and explicit running/waiting text |
| Needs attention / failed attempt | Warning icon and short reason |
| Skipped | Skip icon; distinguish explicit skip from branch choice |
| Branch not selected | Muted branch state; normal non-execution |
| Pending | Empty circle; execution can still reach this step |
| Not run after termination | Muted terminal state; never an ongoing spinner |

Use the declared step title or a generic action title. A collapsed row can show role,
output count, or a short error reason. Expand a row to show error/wait reason first, then
outputs, then an action diagnostics menu when available. Remove duplicate step IDs and
invocation numbers; retain loop paths and retry counts next to the step title. Failed/attention steps initially expand; successful
steps initially collapse. Do not override a user's expansion choices on routine updates.

- Text/Markdown deliveries: name, verdict when present, a 200-character preview, exact
  remaining-character count, and icon-only Copy/Open/Reveal actions. Preview and Copy
  read at most 64 MiB on a utility task; retain only the text preview in view state.
  Open/Reveal remain available when preview loading fails or exceeds its bound.
- JSON action output: expandable fields with 32 children per level and five levels of
  disclosure. Values stay on one line with middle truncation. Open/Copy always use the
  complete result, not the preview.
- Known file artifacts: named absolute `path`/`*_path` fields offer Open/Reveal/Copy.
  File operations retain the history containment gate; the only external artifact location
  is the worktree's `.prowl/handoff/`, with its own link and containment checks. Arbitrary
  strings are never interpreted as paths. Missing files report an explicit action error.
- Pure operations show their recorded execution summary, not an empty Output section.
- Errors: show recorded error details and any partial output. Offer existing permitted
  attention actions only while the run remains active; history is read-only.
- Technical details: step ID, role, attempt, and available invocation times. Do not invent
  precise per-step durations when the record does not contain them.

## Full output opens externally

There is no Expand Full Text action inside the panel. Open Full Output opens the recorded
text/Markdown/JSON file with the default external application, only on explicit user action.
For structured output or errors without a standalone file, materialize a bounded-purpose
viewing file from that specific recorded result, then open it. This file is not a new source
of truth or a durable export. Keep its lifecycle separate from the original run data.

Keep the panel dimensions and preview limits unchanged after opening. If opening fails,
show an inline error and retain Copy/Reveal where applicable. Copy must state whether it
copies the full output or preview; never silently copy a truncated preview as full content.

## Loops, branches, retries, and completion

Group loops by actual iteration, with steps inside each round; do not create future rounds.
Show the chosen conditional branch and collapse the unselected branch. Put retry attempts
inside the corresponding step, default to the latest attempt, and retain earlier errors and
outputs. A successful retry shows a checkmark plus its attempt count.

On completion, update the same panel in place and freeze elapsed time. Do not close it,
switch runs, expand every output, or reset scroll position. On cancellation/interruption,
stop progress indicators and distinguish interrupted work from steps never reached.
Role information and recorded agent icons remain visible after a pane closes. Only live
terminal surfaces get `@pN` focus links; agent detection is not the pane-liveness test. Workflow completion never implies completion of a launched agent's later work.

Footer actions are Run Folder, Log, and a menu for Keep Run and Export. Storage budgets and
cleanup stay in Settings. Retention policy is unchanged. A removed/corrupt record gets an
explicit unavailable state; empty filters get a scoped empty state and broader-scope entry.

## Data and implementation boundaries

Reuse `supacode/Features/Repositories/Views/WorkflowStatusPopoverButton.swift`,
`supacode/Features/Workflow/Models/WorkflowStatusCenterPresentation.swift`, and the existing
history storage/read operations. Extend presentation to terminal states instead of treating
historical records as running. Read details lazily off the main thread; do not run storage
size scans or load full output bodies during toolbar rendering/hover.

Before implementation, audit `supacode/Domain/Workflow/WorkflowRunStore.swift` and
`supacode/Domain/Workflow/WorkflowRun.swift` for these requirements:

1. Persist source and role participation identity for history lookup, including stable
   session identity where available. Current source context and persisted bindings must
   not be assumed to provide the complete historical association contract.
2. Associate each output/error with its step, iteration, and attempt. Latest-result maps
   alone cannot implement attempt history. Add focused records where needed; no log-text
   parsing as the primary data model and no reconstruction of facts that were never saved.
3. Resolve historical titles from a retained execution definition where available, not a
   subsequently edited source workflow. Fall back to recorded IDs when unavailable.
4. Distinguish branch exclusion, skip, and terminal non-execution from absence of a record.
5. Preserve existing privacy and path-containment rules. No aliases, data migration,
   log parsing, or old-result recovery is required; unsupported records are unavailable.

The exact pane/session identity mapping, historical attempt coverage, and viewing-file
lifecycle require a focused code audit before implementation. These are implementation
constraints, not authorization for name-based matching or synthetic history.

## Verification and delivery

- Reducer/model tests: source-or-role union, deduplication, unrelated same-type agents,
  pane/session changes, older records, scopes, terminal states, branches, rounds, retries,
  missing files, and selection stability after completion.
- Output tests: huge text/JSON, bounded loading, correct attempt association, external-open
  failure, and full-content versus preview copy behavior.
- Debug visual checks: Normal/Shelf/Canvas; narrow window; Bell unread/Update states;
  hover-to-panel, click pinning, keyboard dismissal, long content, and last-run completion.
- Verify restart history and closed-role panes. Run required build/checks for implementation
  and update the user manual and toolbar guide with the shipped behavior.
- Implementation now includes the shared step panel, pane/session navigation index,
  persisted step attempts, and terminal history. Live UI acceptance is still pending.

## Execution-summary follow-up plan (2026-09-09)

- Prefer the execution-time rendered title, then the frozen static title or verb summary.
  Never evaluate an old title against current variables.
- Message and launch details show their exact invocation target, a 200-character Markdown
  prompt preview, and full-body Open/Copy/Reveal. A successful launch reports that the
  agent started; it does not imply the agent's task finished.
- Capture target profile/pane identity per attempt, including relaunch results. Keep
  historical identity after closure but show a focus link only for a live surface.
- Action details show the action identifier and typed inputs from that execution's
  `request.json`, loaded lazily through the same bounded containment gate as outputs.
- Notify details show the rendered message and say it was sent to Prowl Notifications.
  Use the declared title or a fixed notification title, not an empty Output section.
- Record condition outcomes and state/control summaries when executed. Pure operations
  show those facts rather than an empty output placeholder. Skipped branches do not claim
  to have evaluated or delivered anything.
- Unify all agent task content as `prompt`, including saved paths and CLI fields. This is
  a clean contract, without aliases, migration, log parsing, or old-content recovery.
- Verify parser/serialization rejection, transport choice, immutable attempt identity,
  recorded inputs/conditions/notifications, bounded previews, file safety, and Debug UI.

### Execution-summary result

Implemented the prompt-only contract and per-invocation target snapshots. History now
shows task-only prompt files with inline Markdown, actual action inputs, rendered notices,
and condition outcomes. Loop rechecks are recorded as checks rather than retry attempts;
failed controls keep their rendered titles. File readers reload when an active attempt
changes or finishes. No legacy result reconstruction remains in step grouping.

Focused regressions first reproduced missing target/condition/title records. Review also
identified initial file-publication races and the 16 MiB preview mismatch; bounded readers
now accept 64 MiB while Open/Reveal do not depend on preview success. The full App suite
passed 3,203 main tests and two process tests. CLI build/smoke, 297 unit tests and 112
integration tests passed, as did `make check` (153 script tests) and the Debug build.

An isolated Debug workflow completed a real launch, multiline scoped-read message,
context action, branch, and notifications. Native checks verified prompt Markdown and
remaining counts, full 386-byte prompt copy, external opening in Typora, action-input copy
against `request.json`, and closed-pane identity without stale focus links.

## UI refinement plan (2026-09-09)

- Keep the native two-column popover. Use baseline-aligned, semantically tinted status
  symbols; remove list status/time text and put run status beside its title.
- Put the local start timestamp and duration on one line. Show step durations only from
  recorded invocation or action timestamps; never infer control-step timing.
- Keep historical role/runtime identity visible. Only a live pane gets an actionable handle.
- Use whole-row step disclosure with hover feedback, trailing duration, and compact output
  actions. Keep retries, loop paths, verdicts, and errors distinct from execution success.
- Replace flattened JSON with bounded nested fields. Use aligned, single-line values with
  middle truncation and explicit file actions for named paths. Preserve file validation.
- Limit delivery previews to 200 characters with an exact remaining-character count.
  Move action diagnostics to a menu; remove redundant execution metadata. Use neutral
  empty-output text rather than claiming old control steps lost output.
- Verify projection boundaries with tests, then inspect the Debug popover and toolbar at
  normal and constrained widths. Update the user manual, run checks/build, and submit a PR.

### UI refinement result

The detail surface now uses compact step rows, typed output fields, and icon-only file
controls. Older records without an associated saved result use `No saved output` rather
than alleging a recording failure. Recorded invocation/action times supply durations;
unknown control-step timing remains a dash.

The additional History-to-Bell hover regression was reproduced in an isolated Debug app:
after switching to Bell and holding the pointer still, History reopened. A window-local
`ToolbarPopoverCoordinator` now owns both presentations, the pin, and the close timer.
Replacing a panel invalidates its ownership, so its late hover/dismiss callbacks cannot
reopen it or dismiss the new panel. TestClock cases cover stale callbacks, close timers,
reverse switching, panel entry, and pinning. Live replay held Notifications open after
more than one second without pointer movement.

File-action acceptance also caught a macOS path-alias mismatch: standardizing a worktree
could turn `/private/tmp` into `/tmp` while its recorded artifact kept the physical path.
The gate now accepts the recorded root or its canonical alias, then validates every
remaining path component without resolving artifact links. `current.md` opened in Typora;
full Markdown copy matched all 3,479 characters rather than the 200-character preview.

Verification: `make check`, 3,198 main tests plus two process tests, and `make build-app`
passed. Debug checks covered the real retained Handoff/Repository Context records in a
separate data directory, compact output layout, live and closed role presentation,
History/Bell hover switching, and Normal/Shelf/Canvas toolbar grouping at a 1,000-point
window width. The final path-alias cases also run in the focused presentation suite.

## Implementation notes (2026-09-09)

- The toolbar and center status use the same detail view. Workflow bell notices carry run
  identity. Storage administration remains in Settings.
- `navigation.json` is a best-effort navigation projection; it must not fail execution
  persistence. Older records fall back to existing metadata/records. Details decode on a
  utility task with a 64 MiB reader bound; oversized or corrupt records remain exportable
  through Settings and show an unavailable detail state.
- Step records retain rendered titles, loop paths, errors, immutable delivery submissions,
  action execution identities, and action outputs. Source identity and known participant session identities are saved.
  Session association uses identities available at binding or subsequent runtime events;
  it never guesses a session for a launch that finished before detection.
- Pure control history stops adding new positions after 10,000 step records, with an
  explicit partial-history notice. Executed action/message records and outputs are retained.
- Full JSON/error views use private temporary directories and the default external app.
  Viewing files are temporary OS data; Export remains the durable-copy operation.
- Self-review fixed terminal records being reintroduced from memory after retention removed
  them. The regression was observed failing before the merge logic was corrected.
- Automated validation: `make check`; `make test` (3172 primary tests and 2 process tests);
  CLI build, smoke, 295 unit tests, and 112 integration tests. PR review and screenshot
  evidence will be added after live acceptance.

### Adversarial review, round 1

All ten findings were confirmed. The first five behavioral regression cases failed before
fixes. The changes preserve provisional and corrected delivery bodies separately, expose
per-attempt action diagnostics, recover exact-ordinal legacy delivery associations, retain
control evaluations on termination, and capture loop paths before stack changes. Projection
now buckets records once and runs off the main actor. Interaction callbacks pin both
entry points; reading a workflow notice marks only that notice read, and explicit workflow
notifications carry run identity. UTF-8 previews preserve incomplete scalar boundaries;
JSON keys and complete previews have byte bounds.

Focused regression coverage includes 10,000 ordered rounds, 2/3/4-byte UTF-8 boundaries,
provisional/redelivered files, cancelled control errors, capped loops, failed action
execution IDs, and explicit-notification identity without duplicate completion notices.

A follow-up concurrency check reproduced two stale-read races. Navigation scans now
snapshot terminal candidates before reading, and late disk detail reads cannot replace
newer in-memory state. Both regressions failed before the fixes; all seven history
reducer/model tests then passed. The complete pre-race-fix suite passed 3179 main tests
and two process-cancellation tests, with a clean Debug build.

### Adversarial review, round 2

The reviewer rechecked all ten first-round findings at `727e3646` and confirmed the two
stale-read fixes. Three P2 gaps remained; all three were reproduced by new failing tests.

- Pending submission metadata now survives activation revocation. Late persistence events
  update archival evidence through the ordered queue, while the run remains cancelled and
  the CLI still reports cancellation. Failed writes add an error, not a saved body reference.
- A legacy action result is recovered only for one completed occurrence of that step.
  Repeated or retried old steps do not receive an invented per-attempt result.
- Each recorded round shows its complete named iteration path, including outer loops.
  Execution Details also exposes the saved path. Zero and future iterations are not added.

The focused domain/reducer run passed 88 tests. Native menu, hover, and screenshot acceptance
remain pending; the third review checks these fixes before that phase starts.

### Adversarial review, round 3

The original round-2 cases passed. One new P2 remained: Retry Save requeued a body after
failure without restoring its pending metadata, which could overwrite a previous submission's
reference or omit a cancelled retry. Both variants failed in regression tests. Initial writes
and retries now use one function that registers metadata and returns the write effect together.
The focused run passed 83 tests, including preservation of both bodies and their acceptance
states. A fourth convergence review checks this narrow change before native acceptance.

### Convergence and live acceptance

The fourth Pi review found no remaining substantiated P0, P1, or material P2 in the
reviewed implementation. The full suite passed 3184 main tests and two process-cancellation
tests; the Debug build and checks passed.

Real workflows in an isolated Debug instance verified a built-in action, an accepted
80-line Pi delivery, and four outputs with distinct nested iteration paths. This exposed
one additional identity gap: Pi's exact managed-hook session was not included when process
detection had no session. History now shares one resolver across admission, observation,
and pane filtering. It uses current exact same-runtime hook evidence, rejects ended
sessions, and accepts only exact detected identities as a fallback. A regression failed
before the fix, then all ten focused review tests passed. A fifth focused review and a
repeat live participant run check this change. The repeat run completed and persisted the
exact Pi hook session for the reviewer; a second workflow started from that Pi pane also
persisted the same identity for the initiator.

Native screenshot acceptance is still pending because the Mac is locked. CLI execution
receipts establish actual workflow behavior; they do not establish toolbar layout,
hover interaction, native script approval, or external output-opening behavior.

### Adversarial review, round 5

A current cooperative progress signal could hide an independently verified hook session.
The reviewer reproduced the missing persisted role identity and an incorrect exact-detector
fallback; the owner independently reproduced both. A producer regression failed before the
fix. The observation store now keeps the last accepted managed hook separately and clears
it together with current signal evidence on every epoch invalidation. Admission, observation,
and pane filtering all use that evidence. General latest-signal behavior is unchanged.

The reviewer replayed completed-run persistence, conflicting detection, session end and
rotation, process replacement, revocation, and new dispatch epochs against the fix. The
final receipt reports no remaining substantiated P0, P1, or material P2 in scope. The full
suite passed 3186 main tests and two process-cancellation tests; the final managed-hook
suite passed 18 tests. Checks and the Debug build passed.

A real Pi workflow sent a current cooperative progress signal, then delivered its result.
The completed history retained the exact hook session. Local evidence under
`build/verification/workflow-step-history/` includes the progress receipt, completed record,
review reports, regression logs, and acceptance checklist. Native UI acceptance still
requires an unlocked Mac; no screenshot or visual-layout pass is claimed.
