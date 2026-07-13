# 046 — Toolbar Status Layout Stability: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-07-13 | Added a bounded, compressible status slot, one-line truncation, accessibility help, focused regression tests, and manual updates. | `8d44fdf1` |
| 2026-07-13 | Verified the docs sync range and refreshed the manual baseline. | This record |

## Outcome & current state (as of 2026-07-13)

- `supacode/Features/Repositories/Views/ToolbarStatusView.swift` owns a 280-point
  ideal and maximum width after horizontal padding. The absence of a minimum width
  leaves a narrow toolbar free to propose a smaller size.
- All status text is single-line and tail-truncates. Toasts expose their original
  full text through hover help and accessibility labels.
- `supacode/Features/Repositories/Views/PullRequestStatusButton.swift` keeps the
  PR badge and check ring while allowing its textual summary to tail-truncate. The
  existing PR hover popover remains the detailed PR and check view.
- `supacode/Features/Repositories/Views/WorktreeDetailView.swift` consumes the
  shared layout in Normal and Canvas modes without duplicate outer padding.
- `supacodeTests/ToolbarStatusViewTests.swift` measures `ToolbarStatusView` through
  `NSHostingView`; it locks the stable ideal width and one-line behavior under a
  constrained width.
- `docs/components/canvas.md` and `docs/components/custom-actions.md` document the
  bounded status area and the existing three-inline-command overflow policy.
- A dedicated debug Prowl instance was driven with `./.build/debug/prowl` on a
  temporary socket. It opened this worktree, created a temporary tab, captured a
  `SELF_VERIFY_TOOLBAR_STATUS` terminal marker, and was fully cleaned up.

## Verification

| Check | Result |
| --- | --- |
| Focused `ToolbarStatusViewTests` | Passed after the implementation; both assertions failed against the pre-change view. |
| `make check` | Passed. |
| `make build-app` | Passed. |
| `make test` | 1,788 passed and 1 failed: `ExternalDiffToolTests.snapshotPairIncludesModifiedAndUntrackedFiles()`. The test's temporary Git commit was rejected by the host's `oc-git-id` hook, independently reproduced outside the test. |
| Debug app CLI round-trip | Passed; screenshot capture was unavailable because the current session lacked Screen Recording permission. |

## Deviations from plan

No implementation deviations. The planned screenshot inspection could not run
because macOS rejected window capture for the current session; the unit test and
dedicated-app CLI scenario supplied the remaining verification evidence.

## Open questions

The external-diff test should be rechecked in CI or an environment without the
host-specific `oc-git-id` template hook. The shared status-view width and
truncation contract is covered by the focused regression test; actual NSToolbar
visual inspection remains unavailable in this session.
