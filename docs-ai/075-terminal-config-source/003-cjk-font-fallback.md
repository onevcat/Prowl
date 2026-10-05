# 075.003 — S2: CJK font fallback

## Context

Second slice of the plan. A Japanese user with no font configuration saw Japanese text in
BIZ UDGothic or BIZ UDMincho, larger than the Latin text around it. The plan's Background has
the root cause in Ghostty's CoreText fallback.

## Change

- `GhosttyCJKFontFallback` (`App/Sources/Infrastructure/Ghostty/GhosttyCJKFontFallback.swift`):
  - `configuresFont(files:)` reads the source's files and their `config-file` includes through
    `GhosttyRawConfig` (S1), which mirrors Ghostty's `Config.loadRecursiveFiles` and skips a
    UTF-8 byte order mark, then the `--key=value` launch arguments that Ghostty reads after the
    files (`GhosttyRawConfig.entries(arguments:)`, stops at `-e`). The active theme can also
    set a font: `themeFileURLs(spec:directories:)` finds it like Ghostty (absolute path, then
    the XDG `ghostty/themes` folder, then `GHOSTTY_RESOURCES_DIR/themes`), and its entries
    count before the user's (Ghostty loads the theme first). With a light/dark pair, a font
    in either theme counts. It tracks the final state of `font-family` and
    `font-codepoint-map`; a blank value clears the list, as in Ghostty.
  - Ranges: kana (including Kana Supplement and Extended), CJK punctuation, BMP and
    supplementary ideographs (Extension A–H, compatibility), vertical and compatibility forms,
    fullwidth forms, halfwidth katakana → CJK family; Hangul, including halfwidth Hangul →
    Apple SD Gothic Neo. Apple SD Gothic Neo has no halfwidth Hangul glyphs, so those still
    use Ghostty's normal fallback.
  - `cjkFamily(preferredLanguages:)` returns the family that CoreText picks for ideographs.
  - `preferredLanguages()` uses a `-AppleLanguages` launch argument, else the global
    `AppleLanguages` (`AppLanguageStore.systemLanguages`), else `Locale.preferredLanguages`.
    Prowl's per-app language does not count.
  - `overrideContents` returns two `font-codepoint-map` lines, or `nil` when the user set a
    font.
- `GhosttyRuntime.makeConfig` loads the lines through `loadCJKFontFallback(into:source:)`
  after the `TERM_PROGRAM` overrides, so the initial load, reloads, and runtime overrides all
  include them.
- `GhosttyConfigSource.userConfigFileURLs` gives the files to scan; the shared source uses
  `GhosttyRuntime.defaultGhosttyConfigFileURLs()` in Ghostty's load order.

## Verification

- `GhosttyCJKFontFallbackTests`: language table, launch-argument and system-language order,
  generated lines load into Ghostty without diagnostics, comment-only and theme-only
  configs, `font-family` / `font-codepoint-map` detection, blank-value reset and file
  order, relative and optional includes, include cycles.
- Debug instance, temporary home with no Ghostty config, `-AppleLanguages (ja-JP)`, and the
  user font Maple Mono NF CN moved away so the candidate set matched a Japanese machine.
  The same sample text was rendered by `main` and by this slice. `ghostty +show-face` on the
  sample attributes the 89 CJK codepoints to BIZ UDGothic without the generated lines and to
  Hiragino Sans with them. A control home with `font-family = Menlo` kept Ghostty's own
  fallback (no lines were added).

## Refs

PR: #861, stacked on #860
