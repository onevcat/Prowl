# 070 — App Localization (Simplified Chinese): Plan

| | |
| --- | --- |
| **Status** | Planned (catalog, tooling, glossary, release sync, and the language setting are in place; `001-action.md` follows when #811 merges) |
| **Anchor date** | 2026-09-18 |
| **Primary PRs** | #811 |
| **Related** | [glossary.md](glossary.md), `.claude/skills/sync-l10n/SKILL.md`, `docs/components/settings.md`, `docs/reference/settings-fields.md` |

## Background

Prowl shipped in English only. PR #811 (an outside contribution) added a String Catalog with a
Simplified Chinese translation of the app UI and an in-app language setting. The maintainer took
the branch over on 2026-09-17 to finish it.

A review of the contribution found one structural problem: the catalog was written by hand and
nothing kept it in step with the code. Inside the PR itself, features that were merged from `main`
after the catalog was made (Remote Mirror, the new workflow sheet) had no entries, so the Chinese
UI showed mixed languages. More problems came from how Swift decides what is localizable:

- `Text("a " + "b")` has type `String`. The compiler does not extract it and SwiftUI shows it
  verbatim.
- A helper that takes `title: String` and calls `String(localized: String.LocalizationValue(title))`
  hides the literal at the call site from the compiler.
- The test host follows the system language. Assertions on English copy failed on a machine
  that runs in Chinese.

## Goals

- Every release ships a finished `zh-Hans` translation of all the copy the compiler can see.
- Everyday work is not blocked by translations. A developer writes localizable English copy and
  moves on; the catch-up happens once per release.
- The catalog does not rot: entries that no code uses are removed at every release.
- UI copy that is not localizable yet is visible as a number that only goes down, and every
  new suspicious literal gets a recorded decision.
- Translations use one agreed vocabulary ([glossary.md](glossary.md)).
- Tests do not depend on the language of the machine.
- The process survives years of growth: the file format matches Xcode, decisions are rules
  where possible, and a second language needs no new tooling.

### Non-goals

- Languages other than Simplified Chinese. The checks handle them, but no translation exists.
- The CLI, command IDs, log lines, agent prompts, and other protocol text. They stay in English.
- Text from third parties (Ghostty, Sparkle).

## Design / Approach

### Everyday work is free; the release sync is strict

| When | What runs | It fails on |
| --- | --- | --- |
| Every change (`make check`, CI) | `scripts/localization.py check` — no build | A broken catalog only: a translation whose placeholders do not match its source |
| Release prep (the `sync-l10n` skill, called from the `release` skill) | `make audit-localization`, then `apply`, `prune`, `triage` | Anything in the audit report, until it is resolved |

A missing translation is **not** an everyday failure. The UI shows the English source for a new
string until the next release sync, which happens on `main` before the version bump, as
`sync-docs` does for the manual. The sync is work for an agent: it reads the audit report,
translates with the glossary, and asks the user only about literals whose purpose is not clear.

### The compiler is the source of truth for coverage

During a Debug build the Swift compiler writes one `.stringsdata` file per source file, next to
the object files. Each file lists the localizable strings the compiler found. This is the same
data Xcode uses to sync a catalog, so a comparison with it is exact: `missing` (the code uses
it, the catalog does not have it) and `unused` (the reverse). A scan of the source text alone
cannot do this, because it cannot tell `String` from `LocalizedStringKey`.

The required languages are the languages that appear in the catalog, so a new language is
enforced from its first entry. The script follows `PROWL_DERIVED_DATA_PATH`, as `make test-app`
does.

### Copy the compiler cannot see: suspects, the baseline, and debt

A plain `String` that reaches the UI looks the same as a log line, so no static check can find
unlocalized copy exactly. The audit therefore reports **suspects**: string literals that read
like copy (a sentence anywhere, one capitalized word that frames a value such as
`Automatic (%@)`, or one capitalized word in a view file), that the compiler did not extract, and
that nobody has decided about yet. A small lexer reads Swift literals, with
interpolation and multi-line literals, so a suspect is the same text the compiler would key.

`scripts/localization_baseline.json` holds the decisions:

| Part | Meaning |
| --- | --- |
| `exemptPaths`, `exemptLinePatterns` | Rules for code that is never UI: the CLI service, agent prompts, logger calls, symbol names. Prefer a rule, because it also covers future code |
| `runtimeKeyPaths` | Files whose titles reach the catalog through a run-time lookup (`AppShortcuts.swift`, the Command Palette items). There, a literal that is a catalog key counts as localized |
| `exemptLiterals` | One literal that is not UI, with a category: `identifier`, `product-name`, `log`, `agent-prompt`, `protocol`, `developer`, `other` |
| `blocked` | UI copy whose value also goes to a CLI response, a log, a file, or another machine, with the reason. It is not debt: it needs its own UI copy before it can be localized |
| `debt` | UI copy that can be localized but is not yet |

A literal counts as localized only at a place (`path:line`) where the compiler extracted it. The
compiler and the lexer report the same line for a literal: 2002 places matched exactly in a
check on 2026-09-18. The same words can be localized in a label and verbatim in a tooltip of the
same file; a comparison across all files hid about 70 such places, and a comparison per file hid
15 more. A decision in the baseline is about the literal, not about one place, and a debt entry
is paid when every place of its literal is localized.

The first baseline (2026-09-18) had about 650 debt literals: alert text in reducers, labels that
views build as `String`, presentation models, and error descriptions. One pass on the same day
made about 500 of them localizable. The 65 that remain are `blocked`, not debt: the same value
also goes to the prowl CLI, a log file, or the workflow run records, so the UI copy must be split
from the protocol text first. The debt is zero. Each release localizes new debt in the files it
touched, within a budget, so the number only goes down. An entry with no open place is reported as
obsolete and removed.

### The catalog has the format Xcode writes

`json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)` with
no final newline is byte-identical to the output of `xcstringstool`. The script writes this
format, so an Xcode build that syncs the catalog and the script do not fight over the file.
Edit the catalog through the script (`apply`, `prune`, `format`), not by hand. An explicit `en`
localization overrides the key as the English text; remove it when the key changes.

### Keys the compiler cannot see

A key that is built at run time must have `"extractionState": "manual"` in the catalog, or the
audit reports it as unused. The shortcut titles in `AppShortcuts.bindings` and the Command
Palette titles are such keys. `AppLanguageTests` checks that each shortcut title has a `zh-Hans`
entry. `LocalizedStringResource(runtimeKey:)` (in `supacode/App/AppShortcuts.swift`) marks the
call sites.

A run-time lookup localizes only the value it returns. When the same `String` also goes to
`Button(title)` or `Text(title)`, that use is verbatim: the Shelf menu items showed English
while their tooltips were Chinese, and the nine `Select Book N` manual entries made the catalog
look complete.

Prefer to let the compiler see the literal:

- Give a helper a `LocalizedStringResource` or `LocalizedStringKey` parameter, not `String`.
  The literal at each call site is then extracted. Do not add a `String` overload next to it: a
  literal selects the `String` overload.
- Write long copy as one multi-line literal with `\` line continuations, not as a `+` chain.
- When one English word has two meanings, use a separate key with a default value, for example
  `String(localized: "agentState.done", defaultValue: "Done")`, and give the entry an explicit
  `en` value.

### The language setting has one source

Settings → General → Language offers Follow System, 简体中文, and English. `AppLanguageStore`
(`supacode/Features/Settings/BusinessLogic/AppLanguageStore.swift`) reads and writes the
per-app `AppleLanguages` default, the key that Foundation consults at launch. macOS writes the
same key from System Settings → Language & Region → Applications. Follow System removes the key.

Prowl keeps no copy of the choice in `settings.json`. The picker and System Settings therefore
always show one value, and the last change wins. `SettingsFeature` reads the value again when the
app becomes active and when the General page appears, because System Settings can change it
while Prowl runs.

A value that Prowl did not write is negotiated with `Bundle.preferredLocalizations`, as the
platform does: `zh-Hans-CN` reads as 简体中文, and a language without a localization reads as
English, because that is what the app shows. Foundation negotiates the language once per
process, so a change applies at the next launch. `SettingsFeature.State.languageChangePending`
compares the predicted language of the next launch with `ResolvedAppLanguage.effective()` to
show the restart hint only when the visible language changes.

### Tests

The `supacode` scheme runs tests with `language = "en"` and `region = "US"`. Tests assert on
literal English copy. Do not call `String(localized:)` on both sides of an assertion: that
compares a value with itself and does not check the text.

## Alternatives & decisions

| Decision | Chosen | Rejected, and why |
| --- | --- | --- |
| When translations are required | At release, by the `sync-l10n` skill | A CI gate on every change (built first, removed 2026-09-18): every PR that adds copy must also edit the catalog, which costs most while the UI changes fast, for users who read English anyway. No enforcement at all: the catalog drifts from the code, which is how #811 started |
| How to find unlocalized `String` copy | Heuristic suspects plus a baseline of decisions | An exact static check: not possible, the type information is not there. A pseudo-localization UI test (`-NSDoubleLocalizedStrings`): finds only the screens it visits and is too heavy for CI; usable as a manual spot check |
| Coverage check input | Compiler `.stringsdata` | A regular-expression scan of the source: many false reports. `xcstringstool sync`: its stale marking was not understood well enough to trust |
| Test language | Pinned in the scheme | `String(localized:)` on both sides of each assertion: the tests pass but verify nothing |
| Feature names | Translated (书架, 画布, Agent 灵动岛, 远程镜像) | English names: mixed text such as “Shelf 书脊” |
| `worktree` | Not translated | 工作树: `worktree` is a git term that users type and search for |
| Workflow `bundle` | Not translated (`Bundle`) | 捆绑包 reads badly; the DSL, the CLI, and the docs say bundle |
| Where the language choice lives | Per-app `AppleLanguages` only | A second copy in `settings.json` with ownership bookkeeping (the first design in #811): it silently reverted a choice made in System Settings, and needed about 170 lines to decide which side owned the key |

## Open

- **Blocked copy.** 65 literals (`python3 scripts/localization.py debt --blocked` lists them with
  the reason). They are UI copy whose value also goes somewhere that must stay in English:
  `WorkflowRunMachine` attention messages (also `log.md`, `state.json`, and the
  `prowl workflow status` JSON), workflow step titles (also the run records), and
  `LifecycleCommandWarning` messages of the managed hooks (also the prowl CLI JSON). To localize
  them, give the UI its own copy per reason and keep the English text for the protocol.
- **Xcode's key order.** The format was verified against `xcstringstool`. An Xcode IDE build
  that rewrites the catalog was not observed yet; if it orders keys differently, follow Xcode.

## Amendments
