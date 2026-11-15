# 070.002 — The Cost of Resolving a `LocalizedStringResource`

## Context

#1074: on macOS 26.6 with Simplified Chinese, activating the window stalled the main thread for
about 1.1 s, and selecting another worktree for about 0.6 s. Samples showed
`String.init(localized:)` → `_copyStringTable` → `_loadStringsFromData` →
`_CFPropertyListCreateWithData` under `View.contextMenu(menuItems:)` and the menu bar commands.

The helper rule of this entry caused it. It said: "Give a helper a `LocalizedStringResource` or
`LocalizedStringKey` parameter". Helpers that return a `String` (tooltips with a shortcut,
`AppShortcuts.helpText`) then called `String(localized:)` with the resource.

On macOS 26 that call does not use the bundle's string-table cache: it parses the whole
`Localizable.strings` again (377 KB of UTF-16 XML for `zh-Hans`). Measured per call, median:

| Call | iOS 26.5 simulator, zh-Hans | macOS 27.0.1, zh-Hans |
| --- | ---: | ---: |
| `String(localized: "…")` (a `String.LocalizationValue`) | 0.7 µs | 0.9 µs |
| `String(localized: LocalizedStringResource)` | 2368 µs | 7.6 µs |

In English the table is about 7 KB, so the same call costs about 75 µs on 26. macOS 27 parses
the table only once for a resource in the default locale, but the call is still several times
slower than the cached path. SwiftUI's own resolution (`Text(resource)`) does not call
`String(localized:)`; only Prowl's explicit calls did.

## Change

- Helpers that turn copy into a `String` take `String.LocalizationValue`:
  `AppShortcuts.helpText(title:commandID:in:)`, the `helpText(title:commandID:)` helpers of
  `ProwlApp` and the `Commands` files, `SidebarListView.topSegmentButton`,
  `ShelfSpineControlButton`, and `CanvasLayoutKind.helpTitle` / `activeHelpTitle`.
  `LocalizedStringResource(runtimeKey:)` became `String.LocalizationValue(runtimeKey:)`.
- The compiler still extracts the literals at the call sites, including interpolations
  (`Select Book %lld`). `scripts/localization.py audit` reported no new unused entry.
- The helper rule in [000-plan.md](000-plan.md) and in `AGENTS.md` now says: a
  `String.LocalizationValue` parameter for a helper that returns a `String`, a
  `LocalizedStringKey` or `LocalizedStringResource` parameter only for a helper that passes the
  copy straight to SwiftUI, and never `String(localized:)` with a `LocalizedStringResource`.

No lint enforces the rule. A module-level shadow of `String.init(localized:)` does not work as a
guard: marked `unavailable`, the type checker picks Foundation's overload instead; marked
`deprecated`, it also flags `String(localized: "…")`. A regular expression cannot see the
argument type.

## Measurement

`scripts/measure-interaction-counts.py` and the `interaction-counts` workflow count the calls in
the running Debug app (see [057.003](../057-performance-benchmark-suite/003-interaction-call-path-counts.md)).
Medians per interaction, 16 worktrees, `zh-Hans`, before the change:

| Interaction | `String(localized: resource)` calls | Table parses, macOS 26.7.2 | Table parses, macOS 27.0.1 |
| --- | ---: | ---: | ---: |
| Worktree switch | 132 | 132 | 0 |
| App activation | 175 (26) / 102 (27) | 175 | 0 |
| App deactivation | 45 | 45 | 0 |

After the change, each count is 0 on both versions (`interaction-counts` run 43681012522).
The same run alternated the two apps on one `macos-26` runner and measured how long a CLI
request waits for the main thread after each interaction (medians, Debug build):

| Interaction | Before | After |
| --- | ---: | ---: |
| Worktree switch, same repository | 798 ms | 368 ms |
| Worktree switch, across repositories | 747 ms | 329 ms |
| App activation | 609 ms | 261 ms |
| App deactivation | 357 ms | 237 ms |

On the macOS 27 runner the same switch went from 338 ms to 299 ms. The remaining time is the
same on both versions and grows with the number of worktrees: a switch dispatches about ten
actions, several of them change state that the sidebar observes, and SwiftUI evaluates each
repository section about five times and every `WorktreeRow` again. That is a separate problem
and is not in this change.

## Refs

- #1074, PR #1116
