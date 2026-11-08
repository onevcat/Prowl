# 090.002 — S1: dim-only composer hints

## Context

`agents.input` from the iOS mirror was refused with `Claude has an existing draft or
attachment ("再测一次，这次把结果通过 mirror 发回来")` while the box only showed Claude Code's
post-turn prompt suggestion. `ClaudeScreenProfile` consulted the styled snapshot only for
`Try "…"` and the queued messages hint; Codex's delivery check required one of eight hint
sentences. Both hints render with SGR dim (`ESC[2m`), verified with a `script -F` capture of
Claude Code 2.1.319 on 2026-11-07.

## Change

- `ClaudeScreenProfile.composerContents(in:styledSnapshot:)` reads the styled snapshot whenever
  the plain box is non-empty; `composerContents(styledSnapshot:)` reads any dim-only box as
  empty, and an image or paste marker as a draft whatever its styling
  (`showsAttachmentMarker`). The styles decide only emptiness; a draft's text still comes from
  the plain screen. A non-empty box without readable styles is unverifiable (nil), not a draft.
- `CodexScreenProfile.liveComposerPromptIndex(in:)` holds the structural check (last `›` row,
  status footer, optional shortcut row). `composerHasNoDraft(styledSnapshot:)` uses it and the
  dim attribute alone; the plain `composerIsEmpty(in:)` keeps the hint list for state detection.
- Tests: the captured suggestion and a rotating Codex placeholder as fixtures; the
  "styled read only for the hint" test became "styled decides only whether the box is empty".
- Docs: `docs/remote-mirror.md`, `docs/components/cli.md`.

## Refs

PR (S1), docs-ai 090 plan.
