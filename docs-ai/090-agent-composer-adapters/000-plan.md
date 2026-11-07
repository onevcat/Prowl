# 090 — Agent composer adapters: dim hints, draft replacement, mirror confirmation: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-11-07 |
| **Primary PRs** | (fill in as they merge) |
| **Related** | [064.014 re-dispatch](../064-agent-completion-signals/014-re-dispatch.md), [089 S6 input while working](../089-mirror-ios-redesign/008-s6-input-while-working.md), [089 S5 terminal keys](../089-mirror-ios-redesign/007-s5-terminal-keys.md), `docs/remote-mirror.md`, `docs/remote-mirror-wire.md`, `docs/components/cli.md` |

## Background

A message sent from the iOS mirror goes through `agents.input`, which shares the input
protection of `prowl agents dispatch` (`WorktreeTerminalState.dispatchInputProtection`): the
agent's input box must read empty, or the Host refuses with `DISPATCH_TARGET_BUSY` and the
message `<Agent> has an existing draft or attachment ("…"). Clear it on Host before dispatching.`

Two things broke on 2026-11-07 with Claude Code 2.1.319 and Prowl v2026.11.2:

1. **A dim hint was refused as a draft.** After a turn, Claude Code shows a *prompt suggestion*
   in the empty box (gray, cursor at column 0, Tab or → accepts it). The suggestion is rendered
   with SGR dim (`ESC[2m`), exactly like the `Try "…"` hint of a fresh session, which Prowl
   already reads as empty. But `ClaudeScreenProfile.composerContents(in:styledSnapshot:)` consults
   the styled snapshot only when the plain text has the shape `Try ".+"` or
   `Press up to edit queued messages`. A free-form suggestion never reaches the dim check and is
   quoted back as a draft. Codex has the same fragility the other way round:
   `CodexScreenProfile.composerIsEmpty` whitelists eight hint sentences.
2. **A real draft can only be refused.** The phone is the person's own voice, but when text is
   left in the box on the Mac, the only way out is to walk to the Mac. A shell pane already does
   better: `sendShellLine` clears the line (⌃E ⌃U), keeps it in the kill ring, and types the
   command. Agent panes have no equivalent, and the composer code is scattered: the
   `AgentComposerProfile` enum (Claude, Devin), an `if agent == .codex` branch, and
   agent-specific hint whitelists.

The suggestion feature backs off after many unused suggestions (`promptSuggestionUnusedStreak`
in `~/.claude.json`), which is why it did not reproduce in fresh panes until that counter was
reset for the capture.

## Goals

- A dim hint never blocks delivery, whatever its wording, for every agent with a styled reading.
- A real draft is a decision for the person, not a dead end: the mirror shows what is in the
  box and can have the Host replace it, or bring the text to the phone to merge it.
- One per-agent abstraction (`AgentComposerAdapter`) owns reading the box, the paste echo rules,
  and the verified way to clear it, so the next agent is one file plus fixtures.
- Replacement is verified on screen before anything is typed, runs under the same key guard as
  the mirror's other keys, and reports how the removed draft can be recovered.

### Non-goals

- Injecting messages outside the TUI (Claude's cross-session inbox socket or channels): they
  arrive as non-user text, cannot answer permissions, and queue until the next turn.
- Replacing drafts without an explicit request: `prowl agents dispatch` and workflow messages
  keep refusing by default.
- Clearing for Devin or image attachments: not verified; the adapter reports `unsupported` and
  the refusal stays.

## Design / Approach

### Verified key behavior (live, 2026-11-07)

| Agent | Key | Idle | Running turn | Multi-line / paste marker | Recovery |
| --- | --- | --- | --- | --- | --- |
| Claude 2.1.319 | Ctrl+S (`chat:stash`) | clears, `› stashed` chip | clears, turn continues | whole `[Pasted text #N]` stashed | Ctrl+S again restores |
| Claude | Esc Esc | clears | Esc interrupts the turn | untested | Up recalls |
| Claude | Ctrl+C | clears | interrupts the turn | untested | Up recalls |
| Codex 0.167 | Ctrl+U | clears one line (two presses per line with its newline) | clears, turn continues | repeat until empty | Ctrl+Y restores the last kill only |
| Codex | Esc | does not clear | interrupts the turn | — | — |
| Codex | Ctrl+C | clears one line, not a multi-line draft | interrupts; quits on an empty box | — | none |

Pasting over a Claude suggestion replaces it; the suggestion survives Ctrl+C and Esc because it
is not input. Both hints are `ESC[2m`.

### S1 — dim-only hints

`ClaudeScreenProfile` reads the styled snapshot whenever the plain box is non-empty; all
non-blank cells after `❯` dim means empty. `CodexScreenProfile.composerHasNoDraft` keeps the
structural checks (prompt row, status footer) and drops the wording whitelist at the delivery
boundary; the plain-text `composerIsEmpty` keeps its list for state detection only. Fixtures from
the `script -F` capture of the suggestion.

### S2 — `AgentComposerAdapter` and draft replacement (Host, wire, CLI)

- `App/Sources/Domain/AgentDetection/AgentComposerAdapter.swift`: `protocol AgentComposerAdapter`
  (`agent`, `name`, `read(plain, styled) -> AgentComposerReading`, `clearPlan`,
  `pasteConfirmation(for:)`, `confirmsPaste`, `dropsEarlyEnter`), `AgentComposerReading`
  (`empty`, `draft(AgentComposerDraft)`, `unrecognized`), `AgentComposerDraft` (`text`,
  `isComplete`: false when a marker stands for content the screen does not show),
  `AgentComposerClearPlan` (`stash(key:restoreHint:)`, `killLines(key:)`, `unsupported`), and
  `AgentComposerAdapters.adapter(for:)`. Per-agent files: Claude (stash ⌃S), Codex (kill lines
  ⌃U), Devin (unsupported). `AgentComposerProfile` is replaced.
- `AgentComposerClearing`: the executor, shaped like `AgentPromptDelivery` (closures, injected
  clock): presses the plan's key under `MirrorKeyGuard`, re-reads until the box is empty, caps
  presses (`2 × lines + 2` for kill lines), and returns the recovery or a partial-clear refusal.
- `DispatchInput.onDraft` (`on_draft`: `refuse` default, `replace`) in `ProwlCLIShared`;
  `prowl agents dispatch --on-draft replace`; the mirror sends it on `agentsInput`.
- `dispatchInputProtection` returns a typed refusal; `AgentDispatchErrorDetails.input` carries
  `reason` (`draft`, `unrecognized`, `editing`, `composing`), the draft (`text`, `is_complete`),
  `replaceable`, and `recovery` (`stash` or none). A replaced delivery reports
  `data.input.replaced_draft` with the same fields.
- `WorktreeTerminalState.submitAgentLine` takes the policy: a replaceable draft under `replace`
  is cleared and re-read as empty before the existing paste-echo path runs.

### S3 — mirror confirmation (iOS)

`ComposerBar` turns a draft refusal into a card: the Mac's draft excerpt with **Replace and
Send** (resends with `replace`), **Bring Draft Here** (prepends the Host text to the phone draft,
enabled when `is_complete`, and marks the next send `replace`), and **Cancel**. A replaced send
shows a quiet note with the recovery hint (`⌃S on the Mac brings it back`) or the removed text.
`MirrorUIFixture` gains a draft-refusal mode; `MirrorSessionTests` cover the parsing and the
policy.

### S4 — docs

`docs/remote-mirror.md`, `docs/remote-mirror-wire.md`, `docs/components/cli.md`,
`docs/components/agent-detection.md`, and the contracts under `docs-ai/013-prowl-cli/contracts/`.

| Slice | Scope | PR |
| --- | --- | --- |
| S1 | Dim-only hints for Claude and Codex | |
| S2 | Adapters, clearing executor, `on_draft`, structured refusal, CLI flag | |
| S3 | iOS confirmation card and notes | |
| S4 | Docs (ships with S2 and S3) | |

## Alternatives & decisions

- **Keep wording whitelists** — rejected: every hint change becomes a refusal again; the dim
  attribute is the signal the TUIs actually emit.
- **Esc or Ctrl+C to clear** — rejected: Esc interrupts a running turn on both agents and does
  not clear a Codex draft; Ctrl+C interrupts, and quits Codex on an empty box.
- **Append the message after the draft, or send blindly** — rejected: the draft would merge
  into the prompt, which is what the refusal exists to prevent.
- **Replace without asking** — rejected for now: Claude's stash is reversible, Codex's kill is
  not; the person decides on the phone, automation keeps refusing unless it passes `replace`.
- **Non-TUI delivery (inbox socket, channels)** — rejected, see Non-goals.
- **A new "fetch and clear draft" command** for Bring Draft Here — rejected: the refusal
  already carries the text; the Host clears at send time under `replace`.

## Amendments
- Updated 2026-11-07: S1 dim-only hints for Claude and Codex — see [002-s1-dim-hints.md](002-s1-dim-hints.md)
- Updated 2026-11-08: S2 adapters, clearing executor, `on_draft` and structured refusals — see [003-s2-adapters-and-replace.md](003-s2-adapters-and-replace.md)
- Updated 2026-11-08: S3 iOS draft card (Replace and Send, Bring Draft Here) — see [004-s3-mirror-confirmation.md](004-s3-mirror-confirmation.md)
