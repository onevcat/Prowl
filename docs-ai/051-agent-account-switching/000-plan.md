# 051 — Agent Account Switching: Plan

| | |
| --- | --- |
| **Status** | Implemented on `feat/agent-account-switching`; built, tested, and exercised in the running app |
| **Anchor date** | 2026-07-25 |
| **Primary PRs** | pending |
| **Related** | [048 agent-runtime-adapters](../048-agent-runtime-adapters/000-plan.md), [045 native-agent-session-detection](../045-native-agent-session-detection/000-plan.md) |
| **Amendments** | [002 account status and sign in](002-account-status-and-sign-in.md), [003 pane account label](003-pane-account-label.md), [004 shared configuration](004-shared-configuration.md) |

## Background

Prowl runs several coding agents in parallel, but every pane inherited the one
system-wide Claude Code and Codex login. Anyone with a personal subscription and
a work seat had to log out and back in to switch, which is impossible to do
per-pane and destroys the other session's state.

Both CLIs already support relocating their entire configuration:

- `CLAUDE_CONFIG_DIR` — verified empirically: `CLAUDE_CONFIG_DIR=/tmp/x claude auth status`
  reports `{"loggedIn": false}` while the ambient session is logged in.
- `CODEX_HOME` — same isolation; `codex` **errors out** if the directory does
  not exist, so Prowl must create it before launching the shell.

Environment variables are per-process, so two panes can hold two different
accounts simultaneously. This makes account switching a configuration problem,
not an authentication problem: Prowl never touches credentials, it only points
the CLIs at a directory.

## Goals

- Named accounts, each a directory holding one Claude Code and one Codex login.
- Per-repository selection, mirroring the existing per-repository
  `githubAccountOverride` ("GitHub identity") precedent.
- A global default so new repositories need no setup.
- Path rules (`~/work = work`) so work repositories pick the work account
  automatically.

### Non-goals

- Any login UI. The first pane on a new account starts signed out; the user runs
  `claude auth login` / `codex login` once, in that pane.
- Account CRUD. An account exists because its name was typed; the directory is
  created on demand.
- Sharing settings between accounts. A relocated config directory is a *full*
  config directory (settings, history, plugins, MCP), which is the price of
  isolation. Users who want shared settings can symlink.
- `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` handling.

## Design

Resolution, most specific first:

1. `RepositorySettings.agentAccount` — explicit per-repository override;
2. longest matching `GlobalSettings.agentAccountRules` entry;
3. `GlobalSettings.defaultAgentAccount`;
4. otherwise `nil` = the system-wide `~/.claude` / `~/.codex` logins.

Longest-prefix (not first-match) wins so that `~/work` and `~/work/client`
behave predictably regardless of the order the rules were typed in.

The account name is a directory name, so names containing `/`, or equal to `.`
or `..`, are rejected outright rather than sanitized; a rejected name resolves to
the next level down, never to a directory outside `~/.prowl/accounts`.

Delivery uses the plumbing that already exists: `WorktreeTerminalState` holds a
`@SharedReader` on the repository settings, `GhosttySurfaceView(environment:)`
already takes env pairs, and `createSurface` already passes
`worktree.scriptEnvironment`. The account env is merged into that one call site,
which means the account applies to newly created panes only — running shells keep
the account they launched with (documented, not fixed: re-execing a live shell
would destroy the user's session).

Rules are edited as text (one `path = account` line) rather than as a list UI:
it makes creation, reordering, and deletion free, at the cost of a small parser.

## Verification plan

- Pure resolution logic (`AgentAccount`) under unit tests: override precedence,
  longest prefix, path-boundary matching (`~/work` must not match `~/workshop`),
  tilde expansion, name rejection, env keys, directory creation, rule text
  round-trip.
- Manual: two repositories on different accounts, `claude auth status` in each
  pane reporting different logins.
