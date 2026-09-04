# 030.015 — Live footer coverage and screen-motion working hold

## Context

Two live panes reported `Idle` while their current UI visibly remained active:

- Pi rendered a framed `── <braille spinner> Working ──` row. Its legacy detector
  accepted only the older bare `Working...` / `Working…` forms.
- Codex rendered `• Waiting for background terminal (... • esc to interrupt)` while
  an `xcodebuild` process was still running. Its typed profile accepted only the
  `• Working (... • esc to interrupt)` label.

Both screens kept changing through a spinner or elapsed counter. The shared stabilizer
did not use that motion: it held a previously recognized Working state for three seconds
from the last positive classifier match, then accepted raw Idle even when the active-screen
text continued to change.

## Change

Add two complementary layers:

1. Treat Pi's framed Working row as explicit live evidence only in the bottom UI region,
   and accept Codex's background-terminal wait row in the existing bottom working-footer
   region. These precise rules keep explainable detection reasons and immediate recognition.
2. Make active-screen motion refresh the shared three-second Working hold when all of the
   following are true: the pane was already Working, the current classifier result is Idle,
   and the active-screen text changed since the previous scan.

The motion fallback deliberately does not promote an Idle or Unknown pane to Working. An
idle agent's composer therefore remains Idle while the user types. Blocked evidence still
bypasses the hold immediately, and an unchanged raw-Idle screen still settles to Idle after
the existing three-second window.

The full active-screen text already keys `AgentScreenScan`, so no new polling or terminal
read is required. The scan comparison becomes liveness input in addition to its existing
memoization role.

## Alternatives and decisions

- **Only add the two strings:** rejected as the sole fix. It repairs the captured versions
  but leaves every agent vulnerable to another live status-label revision or a brief gap in
  its agent-specific rule.
- **Any changed screen means Working:** rejected. Typing into an idle composer also changes
  the screen and would create a false Working-to-Done cycle. Motion only extends a previously
  established Working state.
- **Increase the fixed hold:** rejected. It delays genuine completion while still failing
  any active gap longer than the new constant.

## Verification

- Both live footer tests failed before the classifier changes. The production-wiring test
  failed before the screen-motion seam was added.
- `ScreenHeuristicsTests`, `PaneAgentStateTests`, and `AgentScreenScanCacheTests` pass:
  72 tests, zero failures and warnings.
- `make check` passes, including 82 script tests.
- `make build-app` passes with zero errors and warnings.
