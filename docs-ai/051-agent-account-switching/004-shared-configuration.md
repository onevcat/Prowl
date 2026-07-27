# 051.004 — Sharing Configuration Between Accounts

| | |
| --- | --- |
| **Status** | Implemented and verified in the running app; build, full test suite, swiftlint and swift-format green |
| **Anchor date** | 2026-07-27 |
| **Plan** | [000-plan.md](000-plan.md) · [001-action.md](001-action.md) · [002](002-account-status-and-sign-in.md) · [003](003-pane-account-label.md) |

## Why

First real use exposed the cost of the mechanism. `CLAUDE_CONFIG_DIR` and
`CODEX_HOME` relocate the **entire** configuration, not just the credentials, so
a pane on a named account started from an empty profile: no permissions, no
hooks, no agents, no enabled plugins. The account's `settings.json` held a single
key (`theme`). Switching logins cannot mean losing your setup.

## What was checked first

Orca solves the same problem on the same machine, and its layout is instructive:

- It sets `CLAUDE_CONFIG_DIR` per account exactly as Prowl does
  (`envPatch: { CLAUDE_CONFIG_DIR: location.managedAuthPath }` in its bundle),
  pointing at `claude-accounts/<uuid>/auth/`, which holds only an account marker
  and `oauth-account.json`; the credentials live in its own Keychain service
  (`Orca Claude Code Managed Credentials`). It passes no `--settings` flag, so
  its Claude accounts have the same empty-profile behavior.
- For Codex it does solve it, by building a runtime home
  (`codex-runtime-home/home`) that keeps its own `auth.json`, `config.toml` and
  history while **symlinking the shared parts back** to the real `~/.codex`:
  `AGENTS.md`, `plugins`, `skills`.

So the chosen approach is not novel — it is Orca's Codex approach, applied to
both CLIs.

## Delivered

`AgentAccount.prepareDirectories` now links the user's own configuration into an
account the first time it prepares it (`AgentAccount.linkSharedConfig`):

| CLI | Linked | Stays per-account |
|-----|--------|-------------------|
| Claude Code | `settings.json`, `CLAUDE.md`, `agents/`, `commands/`, `skills/`, `plugins/` | login, `.claude.json`, `projects/`, history |
| Codex | `config.toml`, `AGENTS.md`, `skills/`, `plugins/` | `auth.json`, history, logs |

The source honors an ambient `CLAUDE_CONFIG_DIR` / `CODEX_HOME` before falling
back to `~/.claude` and `~/.codex`, matching what the CLI itself would read (and
what Orca does with `inheritedConfigDir`).

## Decisions

- **Link, don't copy.** A copy drifts from the moment it is made; changes to the
  user's own config would never reach the accounts.
- **Never replace what the account already owns.** Anything present in the slot
  is left alone, so a deliberate per-account override keeps working. The cost is
  that accounts created before this change keep their own `plugins/` or
  `config.toml` until the user removes them; verified on two live accounts.
- **Whole files, no merging.** Claude Code reads one configuration directory and
  does not merge, so a file is either shared or the account's own. There is no
  "shared settings plus a few account-specific keys".

## Known sharp edge

Writing to a shared file from an account pane edits the real file — that is the
intent. But a tool that saves by writing a temp file and renaming it over the
target replaces the *symlink* with a regular copy, after which that account
silently stops following the user's config. Prowl cannot distinguish that from a
deliberate per-account override, so it will not re-link. Surfacing "linked / own
copy" per account in Settings is the obvious follow-up if this bites.
