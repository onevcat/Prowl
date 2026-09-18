---
name: sync-l10n
description: Bring the app string catalog in step with the code at release time - translate new UI copy with the project glossary, remove catalog entries that no code uses, and triage string literals that look like unlocalized UI copy into the baseline (exempt or debt). Run as part of release prep, or on demand when the user asks to sync translations or localization. Nothing in everyday work depends on it.
---

# Sync L10n

Prowl localizes its UI (Simplified Chinese today). Everyday work is **not** blocked by
translations: a developer writes localizable English copy and moves on. This skill does the
catch-up **once per release**, so every release ships with a complete translation of the
copy the compiler can see, and every new suspicious literal has a recorded decision.

Read these first:

- `docs-ai/070-app-localization/000-plan.md` — the design and why it works this way.
- `docs-ai/070-app-localization/glossary.md` — the vocabulary. **Follow it for every value.**
  When a new term needs a decision, add it to the glossary in the same change. The glossary is
  a living document of this skill, so this edit of `docs-ai/` is expected.

All edits to the catalog and the baseline go through `scripts/localization.py`. Do not edit
`supacode/Localizable.xcstrings` or `scripts/localization_baseline.json` by hand: the script
validates placeholders and keeps the catalog in the exact format Xcode writes.

## Guiding principles

- **Translate what is new. Leave what exists.** Do not reword a finished translation unless
  it is wrong or breaks the glossary. Low churn keeps the diff reviewable.
- **Every suspect gets a decision.** Localize it, exempt it with a category, or record it as
  debt. Never make the audit pass by loosening the heuristics.
- **Prefer a rule over a list.** When a whole file or a call pattern is not UI (a new CLI
  handler, a new logger), add an `exemptPaths` or `exemptLinePatterns` rule. Rules absorb
  years of growth; per-literal entries do not.
- **Ask when the meaning is not clear.** A wrong exemption hides UI copy for good. Collect the
  unclear suspects and ask the user once, with the location and your best guess for each.
- **The debt is allowed to exist.** Burn it down within the budget in step 3. Do not start a
  large refactor inside a release. Copy that is `blocked` is not debt: leave it until someone
  separates the UI copy from the protocol text.

## Steps

Work in this order, because a change to Swift code changes what the compiler extracts:
**first every code change (steps 2 and 3), then one rebuild, then translate everything in one
`apply` (step 4), then `prune` (step 5).** The commands are `python3 scripts/localization.py
<command>`; `make check-localization` and `make audit-localization` are wrappers for `check` and
for `build-app` + `audit`.

1. **Build and audit.** `$SCRATCH` is any temporary directory outside the repository.
   ```bash
   make build-app
   python3 scripts/localization.py audit --json > "$SCRATCH/l10n-audit.json"
   ```
   - The audit needs a fresh build, because it reads what the compiler extracted. Build again
     after every change to Swift code.
   - `audit` exits with 1 while any list is not empty. That is a finding, not a failure; do
     not chain it with `&&`.
   - Write down the `debt` number now. The report in step 7 needs it.
   - The JSON has six lists and the debt:
     ```json
     {
       "broken": ["\"Copy %@\": zh-Hans placeholders [] do not match source [@]"],
       "missing": {"Stop Host": ["supacode/Features/RemoteMirror/MirrorHostButton.swift:88"]},
       "unused": ["Legacy banner"],
       "untranslated": ["\"Close\": no zh-Hans translation"],
       "suspects": {"Beta channel %@": ["supacode/Features/Settings/Views/UpdatesSettingsView.swift:53"]},
       "obsolete": ["A literal that left the code"],
       "debt": 622
     }
     ```
   - When every list is empty, go to step 3.

2. **`suspects`** — literals that look like UI copy, are not localized in that file, and are not
   in the baseline yet. The same words can be localized in a menu and verbatim in a tooltip, so
   the report names each place (`path:line`). Open each place and decide:

   | It is… | Do |
   | --- | --- |
   | UI copy, and the fix is local | Make it localizable in code (patterns below). It shows up as `missing` after the rebuild |
   | UI copy, but the fix is not local | Record it as `debt` |
   | UI copy whose value also goes to a CLI response, a log, a file, or another machine | Record it as `blocked` with the reason. It is not debt: it needs its own UI copy first |
   | Not UI: a log line, an identifier, a product name, text for an agent, a CLI or wire-protocol message, developer-only text | Exempt it with that category — or add a rule when the whole file or pattern is not UI |
   | Not clear | Ask the user, all unclear items in one batch |

   - **Local** means: you change only the file of the literal (and the signature of a helper in
     that file), and no test asserts on the text. An error type that several callers show, a
     reducer whose tests compare the text, and text that travels between machines are not local.
   - Code that nothing calls yet is still triaged. Judge by where the type lives and what the
     text says.
   - **When you cannot ask the user** (an unattended run): never exempt an unclear literal, because
     a wrong exemption hides UI copy for good. Localize it or record it as `debt`, and list it
     under "Needs human decision".
   - A decision is about the **literal**, not about one place. Exempt a literal only when
     **every** place is not UI. "Default" in a preview and in a real label is `debt`.
   - A suspect shows every interpolation as `%@`. The real key comes from the compiler and can
     differ (`%lld` for `Int`, `%d` for `Int32`). Do not write translations from the suspect
     text: rebuild and copy the key from `missing`.

   ```json
   {
     "exempt": {"Claude Code": "product-name", "PANE_BUSY: …": "protocol"},
     "blocked": {"Launching %@ failed: %@": "also written to log.md and the prowl workflow status JSON"},
     "debt": ["Unable to create worktree"]
   }
   ```
   ```bash
   python3 scripts/localization.py triage "$SCRATCH/l10n-triage.json"
   ```
   Every key can be left out. `debt --blocked` lists the blocked copy with its reasons, so the
   next sync does not investigate it again; the debt budget never touches it. Categories: `identifier`, `product-name`, `log`, `agent-prompt`,
   `protocol`, `developer`, `other`. The latest decision wins, so a wrong exemption can be moved
   back to `debt`.

   Rules live in three maps of `scripts/localization_baseline.json`. Edit them directly (the
   value is the reason), then run the audit again: `exemptPaths` (a whole file or folder is
   never UI), `exemptLinePatterns` (a call pattern is never UI, such as a logger), and
   `runtimeKeyPaths` (a file whose titles reach the catalog through a run-time lookup, such as
   `AppShortcuts.swift`; there a literal that is a catalog key counts as localized).

3. **Debt budget.** In each release, localize the debt in files that changed since the previous
   release tag, up to about 30 **literals**. Skip this step when the release is urgent. Do more
   only when the user asks.
   ```bash
   python3 scripts/localization.py debt --since "$(git describe --tags --abbrev=0)"
   ```
   (`git fetch --tags` first when `git describe` finds no tag.)
   - The command lists **places**. One literal can have several, and a debt entry is paid only
     when **every** place of its literal is localized. `(also at …)` names the places in files
     that did not change; fix those too, or leave the literal for a later release.
   - Choose what a user sees most: the main window, menus, the Command Palette, alerts. A file
     can be done in part.
   - When you localize a string that the code puts together from parts, localize every part,
     also the parts the audit did not list (`"Listening · " + count`), or the UI mixes two
     languages. Turn a `+` chain into one literal with interpolation; the key changes
     (`"Last seen "` becomes `Last seen %@`) and `prune` still sees that the debt is paid.
   - Suspects and debt share this budget. When there are more local fixes than the budget
     allows, do the most visible ones and record the rest as `debt`.

4. **Rebuild, then translate `broken`, `missing`, and `untranslated` in one file.**
   ```bash
   make build-app
   python3 scripts/localization.py audit --json > "$SCRATCH/l10n-audit.json"
   ```
   ```json
   {
     "Stop Host": {"zh-Hans": "停止主机"},
     "Resetting “%@” restores %@.": {"zh-Hans": "重置“%1$@”会恢复 %2$@。"},
     "Toggle Canvas": {"zh-Hans": "切换画布", "manual": true},
     "Select Worktree 1": {"manual": true},
     "%@:%@": null
   }
   ```
   ```bash
   python3 scripts/localization.py apply "$SCRATCH/l10n-new.json"
   ```
   - `apply` prints what it added and updated; keep the numbers for the report. It rejects a
     value with wrong placeholders and prints why.
   - For `broken`, put the corrected value in the same file. To see the current value, read
     `supacode/Localizable.xcstrings`; reading is fine, only editing goes through the script.
   - Translate into **every** language the catalog uses (`untranslated` names the language).
   - `null` means "do not translate": a key that is only placeholders, punctuation, or a
     sample value such as `XXXX-XXXX`.
   - Keep every placeholder exactly (`%lld` stays `%lld`). When the order changes, number all of
     them (`%1$@`, `%2$lld`).
   - For a short or ambiguous string ("Open", "Run", "%@ in %@"), open the place that `missing`
     names before you translate. One English word can need two translations; then the code
     needs its own key with a default value (see the plan, "Keys the compiler cannot see").

5. **`unused` and `obsolete`.** `prune` removes **every** `unused` entry that is not marked
   manual; there is no selection by key. So look for run-time keys first: a key that the code
   looks up through `LocalizedStringResource(runtimeKey:)` or
   `String.LocalizationValue(<variable>)` is invisible to the compiler. Find the literal in the
   Swift sources:
   ```bash
   git grep -nF '"<key>"' -- 'supacode/*.swift'
   ```
   When it is still a run-time key, mark it with `{"<key>": {"manual": true}}` through `apply`.
   Then:
   ```bash
   python3 scripts/localization.py prune
   ```
   `prune` also removes the baseline entries in `obsolete`: the literal left the code, or every
   place of it is localized now. It never removes a manual entry; when a run-time lookup is
   gone for good, tell the user in the report.

6. **Verify.** `make check` formats changed Swift files, so it comes first.
   ```bash
   make check
   make build-app
   python3 scripts/localization.py audit
   ```
   Repeat from the step that owns a finding until `audit` prints only the `Known debt` line and
   exits with 0. When you changed Swift code, run `make test` as well: tests assert on English
   copy, and a changed key can break one.

7. **Report.**
   ```
   ## L10n Sync
   Translated: <n> new, <n> updated · Removed: <n> unused · Marked manual: <n>
   Suspects: <n> localized, <n> exempt (<categories>), <n> debt, <n> rules added
   Debt: <before> → <after>

   ### Needs human decision
   - <literal> — <location> — <your guess and why you are not sure>
   ```

## Making copy localizable

| Situation | Write |
| --- | --- |
| Literal passed straight to SwiftUI | `Text("…")`, `.help("…")`, `Button("…")` — already localizable |
| The code needs a `String` (state, an alert, a toast) | `String(localized: "…")` |
| A helper takes copy as a parameter | Type the parameter `LocalizedStringKey` or `LocalizedStringResource`, not `String`. Do not keep a `String` overload: a literal selects it |
| A view-only helper returns copy | Return `LocalizedStringKey` |
| Long copy | One multi-line literal with `\` line continuations. `"a " + "b"` is a `String` and is never localized |
| The title is only known at run time | `LocalizedStringResource(runtimeKey:)`, and mark the catalog entry `manual` |
| Data, not copy (a branch name, a path) | `Text(verbatim:)` |
| A title with a value in it, used for a button and a tooltip | `let title: LocalizedStringResource = "Select Book \(index + 1)"`, then `Button(title)`. A `String` passed to `Button` or `Text` is shown verbatim, also when a `runtimeKey` lookup elsewhere localizes the same words |

SwiftLint's `void_function_in_ternary` can misfire on `flag ? String(localized: "a") :
String(localized: "b")` inside a `switch` expression. Use `if`/`else` there.

## Committing

- Stage only `supacode/Localizable.xcstrings`, `scripts/localization_baseline.json`, the
  glossary when it changed, and the Swift files you made localizable. Never `git add .`.
- **As part of release prep** (the `release` skill, on `main`): commit as its own commit before
  the version bump and tag, for example `git commit -m "Sync localization for <VERSION>"`.
  `release.sh` aborts on a dirty tree, and the commit must be an ancestor of the tag.
- **Standalone run** on a branch: open a PR that targets `onevcat/Prowl`.

## Adding a language

Add the first translation in the new language with `apply`. From then on the audit requires
that language for every entry. Add `docs-ai/070-app-localization/glossary-<language>.md`
before you translate in bulk.
