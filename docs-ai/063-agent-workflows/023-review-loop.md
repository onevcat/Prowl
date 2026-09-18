# 063.023 — Review Loop

## Status

Implemented and Debug-accepted, 2026-09-16. PR [#815](https://github.com/onevcat/Prowl/pull/815).
D2 is now named Review Loop (`prowl.review-loop`).

## Contract

The current agent owns the implementation and writes the review brief. One selectable
reviewer Profile opens in a right split in the same tab. The reviewer reads the plan,
checks the actual changes, and reports material correctness, architecture, and UX gaps.
It edits the shared worktree only when main explicitly delegates work. No runtime
or model restriction is imposed.

Each round includes a reviewer report and the main agent's assessment. Main verifies
each finding, uses regression-first fixes where practical, and records reasons for
rejection. The next review has two parts of equal weight: it re-verifies carried-over
findings against those dispositions, and it performs a fresh review of the current diff
with new IDs for new findings. Every report records inspected and uninspected areas so
later rounds can cover the gaps.
Main owns commits, pushes, and existing PR updates by default, subject to the task's
restrictions. Reviewer tests are allowed; main may explicitly delegate other work.

`min_rounds` defaults to 2 and `max_rounds` to 4. Both must be positive, and minimum
must not exceed maximum. Invalid ranges stop before reviewer launch. Clean reports
cannot stop before the minimum or while main reports changed artifacts, failed or
blocked verification, new concerns, or pending delegation. Findings at the maximum
still receive assessment;
the final report must distinguish clean, unresolved issues, and unreviewed last fixes.
Completion of the workflow is not proof that the code is clean.

The workflow preserves the reviewer pane and all deliveries in execution history.
No deadlines, automatic pane closure, or direct agent-to-agent dispatch are required.
The main agent receives each task through the workflow delivery protocol.

## Implementation approach

Compose existing launch, message, typed state, and loop primitives in a built-in
bundle. Keep the briefing first to preserve self-initiated delivery. Validate the
round range with a small general-purpose native `builtin:assert-condition` action
before launch. A local script would add an approval step to a built-in, so it is not
used. The action requires a typed boolean and reports a supplied failure message.
Review instructions live in the bundle prompts, not a separate reviewer skill.
Do not add a second orchestration mechanism or special cases to the runner.

## Validation plan

- Execute the real bundle with the workflow test harness: minimum, clean exit,
  maximum with issues, last-round disposition, and one persistent reviewer.
- Reject contradictory round inputs and invalid or missing verdicts.
- Validate the shipped bundle and build the app.
- Exercise real main/reviewer panes and inspect deliveries and final history.

## Outcome

The built-in bundle, native condition action, schemas, tests, manual, and bundled
workflow skill are implemented. No runner or UI-specific branch was required.
The exported schema now also accepts the existing `builtin:save-handoff` action;
a regression validates every shipped workflow against that schema.

Automated verification:

- New bundle tests were observed failing before implementation, then passing.
- The follow-up verdict, exported-schema coverage, and boolean-template validation
  each had a failing regression before correction.
- The related app workflow/action suites passed (71 reported tests); final focused
  Review Loop tests passed after the follow-up correction.
- CLI build, smoke, 300 unit tests, and 105 integration tests passed. The final
  equivalent schema representation passed all nine schema tests.
- `make check` passed, including 158 script tests; `make build-app` passed.

Two independent Pi review rounds completed. Round 1 found three material gaps:
main follow-up could be mistaken for unchanged/clean; exported action schemas were
incomplete; and boolean inputs accepted plain strings during static validation.
All were reproduced and fixed. Round 2 found no material issues.

Live Debug run `2800B7B5-CD78-497F-9CB3-72621627EED4` completed clean after two
rounds with a Luna main and the selected Pi Reviewer Profile. Main self-started
and delivered its brief; reviewer launched once in the same tab's right split.
The reviewer found a partial-page rounding defect in untracked local changes.
Main observed a failing regression, fixed the defect, and passed four tests.
The same reviewer confirmed the fix in round 2. History retained six deliveries;
both panes remained open. This run preceded the follow-up-verdict prompt refinement;
its exercised transitions are unchanged. Screenshot and run evidence are local.

Final-bundle run `9A37B36F-2662-4479-A8D4-48789C4B4462` completed after exactly
one round with outcome `not clean`. A review-only constraint prohibited edits.
Reviewer and main independently confirmed the pagination defect, main deferred it,
and the summary explicitly recorded the cap and unresolved work. The implementation
remained byte-for-byte unchanged. Both panes remained open.

Native GUI inspection confirmed the built-in entry, selectable reviewer, defaults
2/4, optional focus, and right-split description. The setup preview exposed dynamic
title templates, so the bundle uses static step titles; tasks and summaries still
state the actual review round. No UI code changed. Existing PR publication was not
exercised by the disposable fixtures, which have no remote or PR.

The isolated acceptance instances were closed after verification; completion receipts
and screenshots remain in the local acceptance directory. Personal sessions were not restarted.

## Follow-up: fresh review in later rounds (2026-09-17)

In real use, later rounds concentrated on re-verifying round-1 findings and rarely
searched for new problems. The `next_review` prompt anchored on the previous review:
its title said "updated changes", its first instruction was to verify fixes, "keep
stable IDs" implied a fixed finding set, and the single `## Findings` section had no
slot that required a fresh pass. The prompt now splits the round into carried-over
verification and a fresh review of equal weight, requires `### Carried Over` and
`### New` subsections, gives new IDs to new findings, and treats fix code as new code.
Round 1 must list inspected and uninspected areas so later rounds can cover the gaps.
Section validation only rejects missing sections, so the subsections need no schema
or runner change.
