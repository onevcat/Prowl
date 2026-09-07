# 063.004 — Pane Identity Environment Variable (A1b)

## Context

The A1 review (PR #710) showed that the `prowl-cli` skill taught agents to find themselves with `select(.pane.focused == true)` — the very focus heuristic `create pane` was built to avoid. Prowl already injects `PROWL_WORKTREE_PATH` / `PROWL_ROOT_PATH` into every pane; the pane's own UUID was the one missing fact. The review weighed a caller-pane default for `create pane` against a per-pane environment variable and chose the variable: it is explicit (an unset shell variable fails with `INVALID_ARGUMENT` instead of silently splitting the caller), it serves every command (`send`, `read`, `close`, `create pane`) and the skill's self-guard, and it needs no contract change.

## Change

- `GhosttySurfaceView` generates its UUID before building the surface environment and adds `PROWL_PANE_ID=<uuid>` to every surface (tabs, splits, restored layouts, profile launches); the merged environment is exposed as `launchEnvironment`. A caller-supplied `PROWL_PANE_ID` is overwritten, and profile overrides already reject the `PROWL_` prefix.
- `docs/components/cli.md` gains "Identity: which pane am I?" (the variable, how to resolve the own tab/worktree from it, the inherited-not-verified caveat) and drops the focused-pane self snippet.
- `skills/prowl-cli/SKILL.md` rewritten around a "Who You Are" section and trimmed: stale focused-self guidance removed, duplicated pitfalls merged, the detector-fixture capture recipe reduced to a pointer at `docs/components/agent-detection.md`, command/field claims re-verified against the current CLI and schema (375 → ~170 lines).

## Decisions

- One variable only. Tab and worktree identity are derivable from `prowl list --json` by `pane.id`; `PROWL_WORKTREE_PATH` already exists.
- Convenience identity, not attribution. The value is inherited and forgeable; `handoff` (and later `workflow deliver` / `agents signal`) keep resolving the calling pane from process ancestry.
- `create pane` keeps its explicit anchor (no caller-pane default); the recipe is `prowl create pane "$PROWL_PANE_ID" --direction right`.

## Verification

- `GhosttySurfaceViewTests/launchEnvironmentCarriesThePaneIdentity` (own UUID wins over a forged value, siblings differ); focused suites `GhosttySurfaceViewTests` / `WorktreeEnvironmentTests` / `AgentProfileTests`: 40 passed.
- Live Debug instance on an isolated socket: a new tab's `$PROWL_PANE_ID` equals its `pane.id`; a split created from it reports its own UUID, not the anchor's; from inside the split the skill recipe resolved the correct tab and worktree and `create pane "$PROWL_PANE_ID" --direction down` anchored on itself; `agents read --result-only --json` fails with `INVALID_ARGUMENT` as the skill states.
- `make check`, `make build-app`.

## Refs

- Slice: 063-A1b (release plan R1)
- Branch: `feat/cli-pane-identity-env`
- PR: #713
- Follows: [003-cli-create-pane.md](003-cli-create-pane.md)
