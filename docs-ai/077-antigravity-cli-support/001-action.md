# 077 — Antigravity CLI (`agy`) Support: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-08 | Added runtime, screen detection, exact session ownership, Profiles, workflow binding, icon, and skill installation. | (this branch) |

## Outcome & current state (as of 2026-10-08)

- `DetectedAgent.antigravity` (rawValue `antigravity`) is the persisted identity;
  `agy`, `antigravity-cli`, and `antigravity_cli` classify to it. Bare
  `antigravity` is deliberately unmapped: the desktop IDE ships a same-named
  launcher, so only the CLI entrypoints classify. The score-40 wrapped-runtime
  guard rejects all four names as cmdline tokens, like `grok` and `devin`.
- `agy` spawns a transient `--bg-updater` child inside the pane's foreground job
  (observed live). It shares argv0 but owns no session, so both of its
  candidates score below the TUI's (60/50 vs 80/70) and the TUI always wins the
  pick regardless of enumeration order. The match is pinned to the first
  argument (`agy --bg-updater …`), so a prompt payload mentioning the token
  can't demote the real TUI.
- `AntigravityRuntimeAdapter`: `--model`, `--effort` (suggestions low|medium|
  high|xhigh|max per `agy --help` 1.3.1), Standard renders no flag (the default
  is already guarded), Unrestricted renders `--dangerously-skip-permissions`.
  Seeded interactive uses `--prompt-interactive <prompt>`, headless uses
  `--print <prompt>`; the prompt is always the final value token, preserving the
  seeded-prompt probe contract (`arguments.last == prompt`) that workflow role
  binding relies on. Verified live: `--print`, `--prompt`, and
  `--prompt-interactive` in both `=` and space forms on 1.3.1.
- Screen detection is a legacy detector (`detectAntigravity`): the bottom status
  row is the live boundary — `esc to cancel`/`esc to interrupt` = Working,
  `? for shortcuts` = Idle, matched in a bounded four-row tail because
  `stack_with_default` can append custom status output below the built-in row.
  Trust, permission, and ask-user dialogs are Blocked via a `↑/↓ Navigate` hint
  row paired with a `> ` selected option; a permission dialog keeps
  `esc to cancel`, so the dialog check runs first. A screen with neither footer
  signature is `.unknown`, never affirmative Idle — screen heuristics are this
  runtime's only evidence channel. Answered dialogs in scrollback cannot
  re-report Blocked. A typed profile was deferred:
  `AgentScreenRuleCoverageTests` requires real `prowl read --source detection`
  captures, which need a Debug-app session.
- `AntigravitySessionProfile` resolves `presence/<uuid>.lock` only when the
  descriptor is held open by the pane process — lock files persist after exit,
  so file existence is never evidence. The session id is a UUID (normalized
  lowercase); the transcript resolves to
  `brain/<id>/.system_generated/logs/transcript.jsonl` and the conversation
  database to `conversations/<id>.db`, same id.
- `prowl skills install --target antigravity` links into
  `~/.gemini/antigravity-cli/skills` (user) and `.agents/skills` (project — the
  shared directory Antigravity already reads). The `antigravity` target id is in
  the CLI output schema enums and command help.
- Tab icon: `agy`/`antigravity` → the bundled `Antigravity` asset (Lobe Icons
  mark, MIT), template-rendered.
- No managed hook channel, transcript reader, composer profile, or dedicated
  home — see plan non-goals. Upstream's hooks.json approach is a follow-up.

## Validation

- App builds clean (Debug). Focused suites pass: `AntigravitySupportTests` (5
  tests), `AgentRuntimeAdapterTests`, `AgentClassifierTests`,
  `CommandIconMapTests`, `AgentScreenDetectionTests`, `AgentScreenRuleCoverageTests`,
  `AgentSessionProfileTests`, `AgentSessionResolverTests`.
- CLI: 296 unit + 106 integration + 8 relay tests pass, including the new
  `antigravity` target rows in list/install/uninstall round-trips and schema
  assertions.
- Live `agy` 1.3.1 smoke: trust prompt, working spinner (`⣻ Generating…` +
  `esc to cancel`), permission dialog (`↑/↓ Navigate` + `esc to cancel`),
  idle composer, `--print`/`--prompt`/`--prompt-interactive` all verified;
  process holds `presence/<uuid>.lock` open (lsof) and the file outlives exit.
- `make check`: `swift-format` strict is clean; `swiftlint` reports only
  pre-existing `RepositoryIconImage.swift` violations on untouched files
  (identical on `main`); the changed files lint clean individually.

## Deviations from plan

- **Review-hardened process selection.** First pass demoted only the updater's
  argv0 candidate and matched `--bg-updater` anywhere in argv — the comm-name
  candidate still scored 70 (tying a TUI whose argv0 was unavailable) and a
  seeded prompt containing the literal token could demote the real TUI. Now the
  match is pinned to argv position one and demotes the whole process (60/50 vs
  80/70), covering every registered alias.
- **`observe` keeps scanning past a prompt flag.** Review noted that truncating
  at the first prompt flag under-reported real flags placed after the prompt
  value; the scan now skips flag+value and continues, and `--dangerously-skip-
  permissions` honors last-argument-wins with only the `=false` form counting
  as an explicit off (Go-style bools don't consume the next token).
- **Navigate-hint window widened** from two to three trailing rows so a second
  status row can't mask a live permission dialog into Working.
- **PR review (onevtail) drove three more corrections**: appended
  `stack_with_default` status output could push the cancel footer off the last
  line and read Working as Idle — the footer signatures now scan a bounded
  four-row tail and unmatched layouts return `.unknown` instead of `.idle`;
  permission observation now honors last-argument-wins; the icon was
  re-attributed from Simple Icons (CC0) to Lobe Icons (MIT) — the path data
  matches lobe-icons `antigravity.svg`, and Simple Icons ships no Antigravity
  mark. Also narrowed the flag-shaped-prompt claim: agy intercepts bare
  `--help`/`--version` before flag parsing, so exact-token `--help` prompts are
  unreachable via the space form (equals form works; generated prompts never
  hit it).
- **Follow-up review hardened the same surfaces further**: a pane whose screen
  becomes unclassifiable while holding a retained `.idle` could still satisfy
  dispatch's heuristic evidence — `normalizedState` now treats a raw `.unknown`
  screen as no idle evidence regardless of reason (provider-backed idle still
  wins). The dialog-chrome window was narrower than the footer tail (appended
  stack rows could mask a live dialog into Working) and now tolerates the rows
  a live dialog can show below the hint; `observe` skips values for every agy
  value-flag (`--model`, `--effort`, `--add-dir`, …) so a flag-shaped value
  can't be miscounted, tracks `--model` last-wins inline, and recognizes all
  Go `ParseBool` false spellings.
- **Option spelling is normalized before interpretation**: agy's Go-style
  parser accepts `-name` alongside `--name` (verified `-print`/`-model`/
  `-help` on 1.3.1), so observation maps single-dash forms — including `=`
  values and the `-p`/`-i`/`-c` aliases — to their long names, and stops at a
  bare `--` terminator. This keeps value consumption and last-wins permission
  overrides correct across mixed spellings. The classifier's updater demotion
  accepts `-bg-updater` on the same grounds.
- **A boxed composer below the hint vetoes the dialog read**: a complete
  dialog quoted in transcript (`> ` option and `↑/↓ Navigate` intact) followed
  by a fresh composer used to report Blocked over the live footer. The veto
  needs the composer's two-row signature — a `─` border row AND a `>` prompt
  row — between the hint and the LAST status row, so `>`-leading or
  `─`-dividing `stack_with_default` output cannot veto a live dialog on its
  own. Anchoring on the last status row means a quote that carries the
  dialog's own status line still sees the composer (verified 1.3.1:
  trust/permission dialogs render only footer/status rows beneath the hint).
  The `> ` option window above the hint spans 8 rows for long option lists,
  and the window below the hint spans 10 rows for stacked output.
- **Footer evidence is the first status signature after each composer box**:
  the composer is a `─`-bordered box around a `>` prompt row, and the status
  row renders directly below its bottom border. Each `─`/`>`/`─` box bottom
  contributes the first signature that follows it, and all boxes must agree —
  a transcript-quoted composer or stacked output drawing its own box creates
  a second pair, and mixed signatures read unknown. Below-footer rows never
  reach the evidence, so a status-signature-leading `stack_with_default` row
  cannot supply a spoofed state; without an identifiable box, the bounded
  tail applies the same contradictory-pair rule. This replaces the raw
  tail-suffix scan, where appended rows could push the real footer out of the
  window and let a spoofed `? for shortcuts` row release dispatch readiness —
  a shape onevclaw reproduced end-to-end.
- **Chrome checks use column-0 raw rows**: borders and the `>` prompt render
  at column 0, while wrapped composer content is indented (verified live —
  typing a long line ending in dashes puts `─`-leading text on an indented
  continuation row inside the box). Checking `─`/`>` prefixes on untrimmed
  rows keeps typed or wrapped input from forging a box bottom or vetoing a
  live dialog; status signatures and the navigate hint stay on trimmed rows.
- **Permission observation is conservative in both directions**: an
  unrecognized bare flag anywhere before the decisive permission token —
  off-form or bare — yields unknown rather than an unprovable mode, because a
  hidden or newer string option can consume a known flag's slot and leave a
  value positional (halting Go flag parsing). `=`-valued unknowns are
  self-contained and cannot swallow. The known-bool table (`--sandbox`,
  `--continue`, `--new-project`, `--remote-control`,
  `--disable-slash-commands`, `--bg-updater`) was verified arity-correct on
  1.3.1 (each rejects a positional operand).
- **Prompt binding switched from `=`-form to space form.** The plan assumed
  `--prompt-interactive=<prompt>` was required to protect flag-shaped prompts.
  `adapterSupportsSeededPrompt` (the workflow seeded-prompt probe) requires the
  prompt to be the *last bare token*, so `--flag=value` failed the probe and
  made every Antigravity profile `promptUnsupported` in workflow bindings.
  agy's string flags consume the following token unconditionally — including
  flag-shaped text — so the space form is both correct and contract-compatible.
- **`--effort` takes five values, not three.** `agy --help` on 1.3.1 lists
  `low|medium|high|xhigh|max`; the suggestions list carries all five.

## Open questions

- **Managed hooks** (`hooks.json` named group / `statusLine`): agy supports
  `SessionStart`/`Pre·PostInvocation`/`Pre·PostToolUse`/`Stop`/`SessionEnd` —
  enough for a `hook_antigravity` channel — but configuration lives in fixed
  `~/.gemini` files and this fork writes no user config. Product decision pending;
  upstream #731 is the reference implementation.
- **Blocked coverage gap**: no hook fires while a permission dialog is open
  (mngr verified); statusLine reports `tool_confirmation_pending`. Screen
  detection covers it today.
- **Paste acknowledgement**: unmeasured whether agy drops an early Enter the way
  Devin does; `AgentComposerProfile` stays Claude/Devin-only until observed.
- **`~/.gemini` seed ambiguity**: Gemini CLI's install-detection heuristic sees
  `~/.gemini` which agy also populates — an agy-only install reads as "Gemini may
  be installed". No clean disambiguator short of `command -v`; left as-is.
