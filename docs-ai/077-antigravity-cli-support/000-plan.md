# 077 — Antigravity CLI (`agy`) Support: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-10-07 |
| **Primary PRs** | (fill in as they merge) |
| **Related** | [076-devin-cli-support](../076-devin-cli-support/000-plan.md), upstream `supabitapp/supacode` #731 |

## Background

Google replaced Gemini CLI for individual accounts with Antigravity CLI (`agy`,
a Go binary): on 2026-06-18 Gemini CLI stopped serving Google AI Pro/Ultra/free-tier
requests (enterprise Code Assist licenses and paid API keys remain supported —
`google-gemini/gemini-cli` discussion #27274). Prowl detects and launches 16 agent
CLIs but has no `agy` integration; an `agy` pane reads as a plain shell.

Upstream `supacode` already shipped a native integration in PR `a2a086e4` (#731,
2026-07-29) — after this fork's last reviewed baseline (post-v0.10.5, 2026-07-06),
so it is pending delta in the upstream ledger. Upstream writes a `supacode-hooks`
named group into `~/.gemini/config/hooks.json`; this fork's managed-hook model does
not write user config, so a port is a reimplementation, not a cherry-pick.

## Goals

First-class `agy` support at the same tier Devin landed in 076:

- Process detection (`agy`, `antigravity-cli`, `antigravity_cli` — **not** bare
  `antigravity`, which is the IDE launcher and could false-positive).
- Exact session ownership via open `~/.gemini/antigravity-cli/presence/<uuid>.lock`
  descriptors (verified live on 1.3.1: held open during a conversation, stale on
  disk after exit — the Devin `session_locks` contract verbatim).
- Screen-state detection (legacy detector): `esc to cancel`/`esc to interrupt`
  footer = Working; `↑/↓ Navigate` selection chrome with a `> ` option row =
  Blocked (directory trust, tool permission); `? for shortcuts` footer = Idle.
- `AgentProfileRuntime` + `AntigravityRuntimeAdapter`: `--model`, `--effort`
  (low|medium|high|xhigh|max), Standard (default) / Unrestricted
  (`--dangerously-skip-permissions`), `--prompt-interactive <prompt>` for seeded
  interactive, `--print <prompt>` for headless. `agy`'s flag parser consumes the
  token after a prompt flag unconditionally — even a flag-shaped one — so the
  prompt always travels as that flag's final value token (also what the workflow
  seeded-prompt probe requires).
- `agy` + `antigravity` tab icons (bundled mark, same Simple Icons SVG upstream
  ships).
- `antigravity` skill target (`~/.gemini/antigravity-cli/skills` user,
  `.agents/skills` project — agy reads `.agents/skills/<name>/SKILL.md`,
  binary-verified) and CLI schema enums.
- Workflow token `antigravity` via the existing `DetectedAgent` rawValue set.
- docs/ + skills manual updates; focused tests in `AntigravitySupportTests`.

## Non-goals

- **Managed hook channel (`hook_antigravity`).** `agy` supports JSON hooks
  (`SessionStart`/`PreInvocation`/`PostInvocation`/`Stop`/…, camelCase payload)
  and a `statusLine` state channel — but both live in fixed `~/.gemini` config
  files, and this fork's managed-hook model deliberately writes no user config.
  Needs a product decision first; tracked as follow-up.
- **Typed `AntigravityScreenProfile` + fixture corpus.** Typed rules are obliged
  to carry `prowl read --source detection` captures
  (`AgentScreenRuleCoverageTests`), which require driving a Debug app against a
  live `agy` pane. Legacy detector first; promote with real captures.
- **`agents read` semantic reader.** `brain/<id>/…/transcript.jsonl` exists
  (verified on disk) but decoding stays a follow-up, same as 14 other runtimes.
- **Account-home relocation.** Upstream excludes Antigravity from custom config
  dirs — its state spans fixed `~/.gemini` siblings (`config/`, `antigravity-cli/`,
  root oauth files); `ANTIGRAVITY_APP_DATA_DIR` exists in the binary but is
  unverified. `supportsAccountIsolation` stays false.
- Bare `antigravity` binary classification, `agentapi` shim, `--bg-updater`
  child — none are interactive agents.

## Design / Approach

Mirror 076's shape: `DetectedAgent.antigravity` (rawValue `antigravity`) forces
the compiler through `AgentProfileRuntime`, the adapter switch,
`AgentSessionProfile`, and `detectLegacyScreen`. New files:
`AntigravitySessionProfile.swift` (presence-lock `parsePath`, transcript at
`brain/<id>/.system_generated/logs/transcript.jsonl`) and
`AntigravitySupportTests.swift`. Edited: `AgentClassifier.swift`
(`knownAgentBinaries` + score-40 native-name rejection), `ScreenHeuristics.swift`
(`detectAntigravity`), `CommandIconMap.swift` + `Antigravity.imageset`,
`SkillInstallTarget.swift` + `cli-output-schema.json` enums,
`make-detection-fixture.py` vocabulary, adapter/session test catalogs, docs.

Known lands on `make check`: the skill-target tests enumerate
`["claude","codex","agents","devin"]` → append `antigravity`.

## Alternatives & decisions

- **Legacy detector over typed profile** — fixture-witness obligation can't be met
  without a live Debug-app capture run; every other non-composer runtime is legacy.
- **`antigravity` as the token/case name, not `agy`** — matches upstream and the
  product name; `agy` stays the binary/executable name. Validators warn (not
  error) on `agy` tokens if a user writes one.
- **No `antigravity` bare-name detection** — the Antigravity IDE ships an
  `antigravity`/`agy` shim that can shadow PATH (verified by ecosystem research);
  only `agy`, `antigravity-cli`, `antigravity_cli` classify.
- **Composer acknowledgement skipped** — no evidence agy drops an early Enter the
  way Devin does; `AgentComposerProfile` stays Claude/Devin only until measured.
- **Gemini's `.gemini` install seed left alone** — `~/.gemini` is now ambiguous
  (agy writes root files too), but no clean agy-agnostic seed exists for gemini;
  noted as an open question rather than guessed.

## Open questions

- Whether the composer drops a paste-adjacent Enter (Devin did). If `prowl send`
  drops delivery in acceptance, add `AgentComposerProfile` coverage then.
- `~/.gemini` seed ambiguity for `.gemini` home detection (above).
