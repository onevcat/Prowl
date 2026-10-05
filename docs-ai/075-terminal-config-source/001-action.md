# 075 — Terminal Config Source and CJK Font Fallback: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-05 | Reproduced the report in a Debug instance: no Ghostty config, `ja-JP`, kana-first Japanese text rendered in BIZ UDGothic with oversized glyphs | — |
| 2026-10-05 | S1: `GhosttyConfigSource`, one config builder, dedicated config file in Settings → General → Terminal Config | #860, [002](002-dedicated-config-file.md) |
| 2026-10-05 | S2: CJK font fallback when the active config sets no font | stacked on #860, [003](003-cjk-font-fallback.md) |

## Outcome & current state (as of 2026-10-05)

- `App/Sources/Infrastructure/Ghostty/GhosttyConfigSource.swift` — where the user's config
  comes from; loading, the editable file, the raw theme file, and the files to scan.
- `App/Sources/Infrastructure/Ghostty/GhosttyRuntime.swift` — `makeConfig(source:overrideFileURLs:)`
  builds every config: source, CLI args, `TERM_PROGRAM`, CJK fallback, runtime overrides.
- `App/Sources/Infrastructure/Ghostty/GhosttyCJKFontFallback.swift` — font detection,
  language choice, and the generated `font-codepoint-map` lines.
- `App/Sources/Features/Settings/Views/TerminalConfigSettingsSection.swift` — Settings UI;
  `GlobalSettings.ghosttyConfigPath` stores the choice.
- User docs: `docs/components/terminal.md` (Ghostty config, CJK font fallback).

## Deviations from plan

- The plan did not say which language list picks the font. The implementation uses a
  `-AppleLanguages` launch argument first, then the global system languages, and ignores
  Prowl's per-app language. The launch argument also makes the behavior testable without
  changing the system language.
- S1 added `~/` display of the dedicated path in Settings.

## Open questions

- A user who sets only `font-family-bold` or `font-family-italic` still gets the mapping;
  Ghostty applies codepoint overrides to every style. Not observed in practice.
- `GhosttyRuntime.defaultFontSize()` reads the `f32` `font-size` into a `Double`, so it
  returns 0. Found during this work; not changed here.
