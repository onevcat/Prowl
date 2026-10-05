# 075 — Terminal Config Source and CJK Font Fallback: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-10-05 |
| **Primary PRs** | #860 (S1), S2 stacked on #860 |
| **Related** | [007-ghostty-embedding-integration](../007-ghostty-embedding-integration/000-plan.md), `docs/components/terminal.md`, issue #693 |

## Background

Prowl builds its terminal configuration from Ghostty's own default config files. Two problems
come from that:

1. **No isolation (#693).** A user who also runs standalone Ghostty cannot give Prowl a different
   terminal setup. Every change applies to both apps.
2. **Bad CJK rendering on first launch.** A Japanese user with no font configuration sees
   Japanese text in BIZ UDGothic or BIZ UDMincho, with glyphs that are larger than the Latin
   text and that change between fonts. The cause is in Ghostty's CoreText fallback
   (`ThirdParty/ghostty/src/font/discovery.zig`):
   - Only CJK Unified Ideographs (U+4E00–U+9FFF) use `CTFontCreateForString`, which follows the
     system language (`ja` → Hiragino Sans).
   - Kana, CJK punctuation, and fullwidth forms use `CTFontCollection` discovery sorted by
     "has the codepoint > monospace > style > glyph count". Fonts that claim monospace and
     contain kana win: BIZ UDGothic, BIZ UDMincho, Osaka-Mono, Lantinghei, LingWai, AB_appare.
     Most of them are on-demand MobileAsset fonts that macOS downloads for CJK languages, so
     the result depends on the machine, not on a macOS version.
   - The first fallback face that loads joins the collection, and later ideographs resolve
     to it before the ideograph path runs. One kana at the start of the output is enough to
     move a whole session to that font. Each fallback face also gets its own size adjustment,
     so mixed faces have mixed sizes.

   Ghostty writes a comment-only template config on first load, so "a config file exists"
   does not mean "the user configured something".

## Goals

- S1 (#693): Settings → General → Terminal Config can point Prowl at one dedicated Ghostty config
  file. That file replaces Ghostty's default files; it does not layer on top of them.
- S2: When the active config source sets no `font-family` and no `font-codepoint-map`, Prowl
  maps the CJK ranges to the system CJK font for the user's languages, so CJK text uses one
  face with one size.

### Non-goals

- No change to Ghostty's fallback code (no fork patch, no GhosttyKit rebuild).
- No in-app font picker.
- No change for users who configured fonts; their `font-family` or `font-codepoint-map` wins.

## Design / Approach

### S1 — config source

- `GhosttyConfigSource` (`App/Sources/Infrastructure/Ghostty/GhosttyConfigSource.swift`):
  `.ghosttyDefault` or `.file(path:)`. It owns everything that depends on where the config
  comes from: how to load it into a `ghostty_config_t`, the file that **Open Config** edits,
  the file that `prowl-split-divider-width` and the raw `theme` spec are read from, and the
  extra `ghostty +show-config` arguments for the theme-fallback probe.
- `GhosttyRuntime` keeps the current source. `loadConfig` and `applyRuntimeOverridesIfNeeded`
  share one builder that loads the source, the recursive `config-file` includes, the
  `TERM_PROGRAM` overrides, and the runtime override files.
- `GlobalSettings.ghosttyConfigPath: String?` (nil = Ghostty's files). `SettingsFeature` stores
  it through `setGhosttyConfigPath`; the app scene pushes changes to the runtime with
  `onChange`, the same way it syncs keybindings.
- A dedicated file that does not exist loads nothing (Ghostty's built-in defaults). The
  Settings row shows a warning; Prowl never falls back to the shared files silently.

### S2 — CJK font fallback

- After the source is loaded, scan its files and their `config-file` includes for the final
  state of `font-family` and `font-codepoint-map` (a blank value resets the list).
  `ghostty_config_get` cannot read either key (`RepeatableString` / codepoint map have no
  C value), so the scan reads the raw text.
- If both are unset, load a generated override with `font-codepoint-map` entries for kana,
  CJK punctuation, CJK ideographs, compatibility forms, and fullwidth forms. The font is
  picked from the first CJK language in the system preferred languages (`ja` → Hiragino Sans,
  `ko` → Apple SD Gothic Neo, Traditional Chinese → PingFang TC/HK, other Chinese and no CJK
  language → PingFang SC), which matches what CoreText returns for ideographs. Hangul always
  maps to Apple SD Gothic Neo.
- A mapped font that lacks a codepoint is skipped by Ghostty's codepoint-override lookup, so
  the normal fallback still covers the gaps.

## Alternatives & decisions

- **Dedicated file replaces vs. layers on the shared config** — replace. Isolation is the point
  of #693, and a layered file cannot remove a shared setting.
- **Fallback only when no config exists** — rejected. Ghostty's template makes the file exist
  after the first launch, and users with a theme-only config would keep the bug.
- **`font-family` chain instead of `font-codepoint-map`** — rejected. A configured
  `font-family` replaces the embedded JetBrains Mono as the primary font unless JetBrains Mono
  is also installed.
- **Inject the map even when `font-family` is set** — rejected. Codepoint overrides win over
  the primary font, so a configured CJK-capable font (for example Maple Mono NF CN) would lose
  its CJK glyphs.
- **Patch Ghostty's discovery** — rejected for now: fork cost and a GhosttyKit rebuild for a
  problem that configuration can solve.

## Amendments
- Updated 2026-10-05: S1 dedicated config file implemented — see [002-dedicated-config-file.md](002-dedicated-config-file.md)
- Updated 2026-10-05: S2 CJK font fallback implemented — see [003-cjk-font-fallback.md](003-cjk-font-fallback.md); action log in [001-action.md](001-action.md)
