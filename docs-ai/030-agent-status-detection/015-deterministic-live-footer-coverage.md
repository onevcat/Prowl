# 030.015 — Deterministic live footer coverage

## Context

Two live panes reported `Idle` while their current UI visibly remained active:

- Pi rendered a framed `── <braille spinner> Working ──` row. Its legacy detector
  accepted only the older bare `Working...` / `Working…` forms.
- Codex rendered `• Waiting for background terminal (... • esc to interrupt)` while
  an `xcodebuild` process was still running. Its typed profile accepted only the
  `• Working (... • esc to interrupt)` label.

An initial fix also treated any changing active-screen text after a recognized Working
frame as continued work. Review found that user input changes the same screen snapshot,
so an agent that had already finished could remain Working indefinitely while the user
edited its composer.

## Change

- Treat Pi's framed Working row as explicit live evidence only in its bottom UI region.
- Treat Codex's background-terminal wait row as explicit live evidence only in its
  existing bottom working-footer region.
- Do not infer agent activity from generic screen motion.
- Remove the shared time-based Working hold. Explicit Working, Blocked, and Idle screen
  observations now apply on the next active scan. The existing `.unknown` viewer-overlay
  state remains a deterministic no-signal case and preserves the previous trusted state.

## Alternatives and decisions

- **Generic screen motion:** rejected because the terminal snapshot carries no provenance;
  user input, terminal echo, runtime output, and UI repaint all appear as text changes.
- **Input-attributed motion:** rejected because mixed input/output frames still require a
  timing policy, and would leave dispatch correctness dependent on heuristic attribution.
- **Fixed Working hold:** retired because it delays genuine completion and can conceal a
  missed Idle transition. Runtime-specific live UI should be represented by explicit rules.

## Verification

- `PaneAgentStateTests` asserts that raw Idle ends Working immediately for every detected
  agent. The related state, screen-profile, and scan-cache suites pass: 68 tests, zero
  failures and warnings.
- `make check` passes, including 82 script tests.
- `make build-app` passes with zero errors and warnings.
