# 046 — Toolbar Status Layout Stability: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-07-13 |
| **Primary PRs** | TBD |
| **Related** | [024-canvas-interaction-evolution](../024-canvas-interaction-evolution/000-plan.md), [028-pr-status-tracking](../028-pr-status-tracking/000-plan.md), [033-ui-refresh-2026-05](../033-ui-refresh-2026-05/000-plan.md), [002-custom-commands](../002-custom-commands/000-plan.md), issue #471, `docs/components/canvas.md` |

## Background

`ToolbarStatusView` is the `.principal` toolbar item in both Normal and Canvas
views. Its intrinsic width currently changes whenever the view switches between a
time hint, a pull-request/check summary, and a transient toast. AppKit consequently
re-measures the toolbar and nearby controls shift horizontally.

Issue #471 also reports constrained space for custom command buttons. That is only
partly related: Normal view intentionally shows at most three command buttons and
places the remainder in an overflow menu. The fix must not alter that command policy.

An earlier width-measurement and animation experiment (`4c73b76b`) was reverted by
`09443b3f` because the transition introduced more visual churn than a direct snap.

## Goals

- Reserve a stable, bounded ideal width for the center status area in Normal and
  Canvas views.
- Allow the status area to compress when a narrow toolbar needs the space.
- Keep transient toast messages readable through hover and accessibility when their
  visual text truncates.
- Preserve compact PR identity and CI-state signals, with the existing PR popover
  remaining the source for full details.
- Add a regression test for the view's width and single-line contract.

### Non-goals

- Do not reintroduce status-width measurement or width animation.
- Do not change the three-inline-custom-command overflow policy.
- Do not replace textual toast or PR semantics with color-only indicators.
- Do not alter PR refresh, check classification, or command execution behavior.

## Design / Approach

1. Make `ToolbarStatusView` own its status-slot layout so both existing call sites
   inherit the same behavior. After its horizontal padding, apply a 280-point ideal
   and maximum width without a minimum width; an unconstrained toolbar therefore
   keeps a stable reservation, while AppKit may propose a smaller width in a narrow
   window.
2. Apply one-line tail truncation to status text. Attach full toast text as the
   hover help and accessibility label. PR status keeps its badge and check ring;
   its existing hover popover continues to expose the complete title and checks.
3. Add a macOS Swift Testing regression using `NSHostingView.fittingSize` for short
   and long toast content. It will prove the common ideal width, the upper bound,
   and single-line behavior under a constrained proposal.
4. Update the Canvas and Custom Commands manual only to document the bounded status
   area and the unchanged overflow behavior, then refresh the docs sync baseline.

## Alternatives & decisions

| Alternative | Decision |
| --- | --- |
| A fixed `.frame(width:)` slot | Rejected. It cannot yield space on narrow toolbars. |
| `maxWidth` alone | Rejected. Short states retain their intrinsic width and still cause layout movement. |
| Width measurement or animation | Rejected. Historical implementation was intentionally reverted for visual churn. |
| Color/count-only PR state | Rejected. It loses meaningful toast and PR semantics; badge, ring, tooltip, accessibility, and popover already provide layered information. |
| Ideal + maximum width, no minimum | Chosen. It makes normal-state allocation stable while retaining compression under toolbar pressure. |

## Verification

- Run the focused `ToolbarStatusViewTests` case with `xcodebuild`.
- Run changed-file formatting and repository checks.
- Build the Debug app with `make build-app`.
- Launch a dedicated self-verify Prowl instance and inspect a narrow normal/canvas
  toolbar screenshot; clean up the temporary app and socket afterward.

## Amendments
