# 052.002 — Account Status and Sign In

| | |
| --- | --- |
| **Status** | Implemented; build, full test suite, swiftlint and swift-format green |
| **Anchor date** | 2026-07-26 |
| **Plan** | [000-plan.md](000-plan.md) · [001-action.md](001-action.md) |

## Why

The first cut let a user name an account but never showed what was inside it.
Live use proved that gap costs real time: a login made while the path rules were
broken landed in the default account, and finding that out required running
`claude auth status` by hand against each directory. The settings pane must
answer "which login is in which account?" itself.

## Delivered

- **`AgentAccountStatusClient`** (`supacode/Clients/AgentAccount/`) — asks each
  CLI what it sees in an account's directory, through the user's login shell
  (`/usr/bin/env VAR=<dir> claude auth status`, same for `codex login status`).
  Built as `live(shell:)` like `AgentRuntimeClient`, so the shell is injected
  rather than looked up inside an isolated closure.
- **`AgentAccountStatus`** — `signedIn(String)` / `signedOut` / `unavailable`
  per CLI, with the parsing as static functions so tests never touch a process.
- **`AgentAccountCLI`** — display names plus `loginCommand(forAccountNamed:)`,
  which bakes the account directory into the command.
- **UI** — an "Agent Accounts → Logins" list in `AdvancedSettingsView`
  (`AgentAccountStatusRow`): identity per CLI, **Sign In** per CLI, one
  **Refresh**. Rules rows also lost their repeated inline labels
  (`.labelsHidden()` plus one header row) — in a `Form` every `TextField` was
  rendering its own label, which made the placeholder read as a value.
- **`AppFeature`** handles `settings.delegate.signInAgentAccount` by preparing
  the account directories and opening a tab with the login command in the
  current worktree.

## Notable details

- Both CLIs **exit non-zero when signed out** (`claude auth status` still prints
  its JSON, `codex login status` prints `Not logged in`), so the exit code is
  useless as a signal: the client reads `ShellClientError.stdout` and decides
  from the payload alone. Verified against both binaries before writing the code.
- The login command carries `CLAUDE_CONFIG_DIR` / `CODEX_HOME` explicitly rather
  than relying on the pane's own account. Sign In is pressed from Settings, where
  the current repository may resolve to a *different* account — without this the
  login would silently land in the wrong slot, which is exactly the failure the
  feature exists to prevent.
- An account with no directory yet is reported as signed out without spawning
  anything; asking `codex` about a missing `CODEX_HOME` is an error, not an answer.
- The two CLIs **answer on different streams**: `claude auth status` prints JSON
  on stdout, `codex login status` writes to stderr with an empty stdout. Reading
  stdout alone reported an installed `codex` as "Command line tool not found" —
  caught by running the built app, not by tests. The client now takes whichever
  stream carries text.
- The button follows the state: **Sign In** when signed out, **Sign Out** when
  signed in, nothing when the CLI is missing. A row that already shows an
  identity offering only "Sign In" was the first thing that read as broken.
