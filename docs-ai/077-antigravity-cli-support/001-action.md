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
  `? for shortcuts` = Idle. Trust, permission, and ask-user dialogs are Blocked
  via a `↑/↓ Navigate` hint row in the last two rows paired with a `> ` selected
  option; a permission dialog keeps `esc to cancel`, so the dialog check runs
  first. Answered dialogs in scrollback cannot re-report Blocked. A typed
  profile was deferred: `AgentScreenRuleCoverageTests` requires real
  `prowl read --source detection` captures, which need a Debug-app session.
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
- Tab icon: `agy`/`antigravity` → the bundled `Antigravity` asset (Simple Icons
  mark, CC0), template-rendered.
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
  permissions` honors only the `=false` form (Go-style bools don't consume the
  next token).
- **Navigate-hint window widened** from two to three trailing rows so a second
  status row can't mask a live permission dialog into Working.
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
