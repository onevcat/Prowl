# 084 — SSH Remote Folders: Plan

| | |
| --- | --- |
| **Status** | In progress |
| **Anchor date** | 2026-10-22 |
| **Primary PRs** | #952 (this plan); A1 #955; A2 #956 |
| **Related** | [082-ssh-remote-agents](../082-ssh-remote-agents/000-plan.md) (L0, shared contracts C1–C6, L1f–L1h, L2), [002-spike-findings.md](../082-ssh-remote-agents/002-spike-findings.md), `docs/components/agent-detection.md` |

## Background

082 planned three layers for repositories on another machine: L0 detection, L1 remote
folders, L2 persistent sessions. L0 shipped in #924–#933 and #937 (with #946 and #949). The
082 L1 section was written before any of that code existed. On 2026-10-22 it was calibrated
against `main` (`09dd90a9`); the gaps below changed the order and several mechanisms, so the
core of L1 (082 slices L1a–L1e) moves to this entry. 082 keeps the shared contracts, L1f
(remote Profiles), L1g–L1h (interactive authentication) and L2.

| # | 082 assumed | Code on 2026-10-22 |
| --- | --- | --- |
| G1 | Replace `Repository.rootURL` and `Worktree.workingDirectory` | A third path field, `Worktree.repositoryRootURL`, has about 47 model uses (63 textual matches across types). `Repository.ID` and `Worktree.ID` are local path strings that leave the app: persisted ID lists, CLI `--worktree`, `ListCommandPayload`, Mirror `worktreeID`. Remote identity must be decided first, not in L1d |
| G2 | A new `resolve(kind:location:)` policy | `Repository.Capabilities` exists (8 flags by `Kind`, 64 uses in 17 files) |
| G3 | Callers that bypass `ShellClient`: clone, external diff, diff window, outgoing changes, workspace runner, archive script | The workspace runner and the archive script use the injected `ShellClient`. The real bypasses: `GitClient` takes a `ShellClient` but defaults to `.live`, and every `GitClientDependency.liveValue` closure builds a default instance; four ad-hoc `GitClient()` instances (`OutgoingChangesClient`, `ExternalDiffSnapshotClient`, `DiffWindowState` ×2); clone (`CloneRepositoryView`); `HandoffStore`; `WorktreeBranchReader` in `WorkflowRuntimeComposition`; `WorkflowNativeActions`; and six `gh` calls in `GithubCLIClient` that infer the repository from the cwd |
| G4 | One polling command: HEAD, branch, porcelain status, worktree list | The local "dirty" state is the `lineChanges` count, which 082 deferred. Refresh also uses worktree creation time (order), the remote URLs (code host and PR refresh) and `isBare` |
| G5 | C4 separate lanes, C5 structured commands | `RemoteConnectionOwner` runs only the probe; it has no general command path and no lanes. `RemoteShellCommand` has no production caller. `RemoteConnectionRegistry` already counts leases per `ConnectionKey` and shuts the owner down (`-O exit`) only on the last release |
| G6 | Optional host on `PersistedRepositoryEntry`; the snapshot cache keeps remote entries | The snapshot cache drops the whole snapshot when one path fails `fileExists`. A load failure prunes pins and `prowlCreatedWorktreeIDs` (archived worktrees have a guard). The settings directory `~/.prowl/repo/<basename>` (`ProwlPaths.swift`) collides for two local repositories with one name today |
| G7 | Type `ssh -t`, then type scripts as further input | A host key or password prompt reads the typed script; the remote login shell (for example fish) parses ssh's command string with its own quoting |
| G8 | A split inherits the remote cwd from the probe | Ghostty's OSC 7 handler rejects non-local hosts. The probe has the cwd, but `RemotePaneTracker` does not expose it; agent entries report a local cwd for remote agents |
| G9 | No consent rule for L1 | A Prowl-opened remote tab would show the L0 consent panel; with L0 `disabled` it gets no host label |
| G10 | Profiles compile from a structured invocation | `AgentInvocation` is structured; the environment in `AgentProfileLaunchPlan` is pre-rendered shell text |

## Goals

- Remote repositories and worktrees in the sidebar next to local ones, with worktree list,
  create, remove and rename, branch and dirty state, and GitHub PR status.
- Tabs, splits, setup, run and custom scripts open on the host; layout restore reconnects.
- Local repositories behave exactly as before through every preparatory slice.

### Non-goals

- Remote Profile launches (082 L1f; unavailable with a reason until then), password and 2FA
  hosts (082 L1g–L1h), persistent sessions (082 L2). Until L1g, a remote folder needs a host that the side channel can
  reach with `BatchMode=yes`.
- Diff window, external diff, outgoing changes, icon detection, workspaces, Finder, open in
  editor, clone to remote, archive script: unavailable for remote folders, with a reason.
- Remote CLI and workflow participation from remote panes (low priority, not planned).

## Design / Approach

### Identity and location (D1)

`RepositoryLocation` is `.local(URL)` or `.remote(hostProfileID: UUID, path: String)`,
orthogonal to `Repository.Kind`. The remote path is canonical on the host (`cd <p> && pwd -P`,
no trailing slash). A `Worktree` shares its repository's host.

The ID is the encoded location. `Repository.ID` stays `String`, so persisted data, the CLI
wire format and Mirror keep their types.

| Kind | ID | Example |
| --- | --- | --- |
| Local | Standardized absolute path (today's value) | `/Users/me/src/app` |
| SSH remote | `ssh:<host-profile-uuid>:<canonical-path>` | `ssh:5c1f0a8e-7d1b-4c63-9a3e-2f1b6c9d0e42:/home/dev/src/app` |

- `ssh:` names the registry of the UUID (`HostProfile`). Another kind of remote would get its
  own prefix.
- The UUID is lowercase and 36 characters, then `:`, then a path that starts with `/`. The
  fixed length makes parsing unambiguous, so the path is stored raw: no percent-encoding, and
  spaces, `%`, `#`, `:` and Unicode are lossless.
- No alias or hostname in the ID: both can change, and a rebind keeps the UUID.
- Local IDs start with `/` and remote IDs with `ssh:`, so they cannot collide and local data
  needs no migration. An ID in neither form is unknown; normalizers never prepend the home
  directory to it (today's `RepositoryPersistenceClient` normalizer does).
- One codec: `location.id` encodes, `RepositoryLocation(id:)` decodes. No code builds or
  splits an ID string by hand.
- People never see the ID. UI and CLI display `alias:/path` (scp style). CLI `--worktree`
  also accepts `alias:/path` and resolves it to the UUID form at once; a bare path matches
  local worktrees only.

### Model migration

- `Repository` stores `location` and exposes `localURL: URL?` (nil for remote). `Worktree`
  stores two locations on one host: `location` (its working directory) and
  `repositoryLocation` (its repository root; different for a linked worktree), with
  `localURL` and `repositoryLocalURL`. `.local` convenience initializers keep the existing
  `init(rootURL:)` and `init(workingDirectory:repositoryRootURL:)`, so the about 250
  constructor sites in tests do not change.
- `rootURL` and `workingDirectory` first become deprecated forwards to `localURL!`, and
  `repositoryRootURL` to `repositoryLocalURL!`; call sites migrate by category; the forwards
  are then deleted.
- Each call site does one of: go through the host, sit behind a capability, or unwrap because
  it is local by construction (`NSOpenPanel`, clone destination).
- The six copies that treat a plain folder as its own worktree become one
  `Repository.terminalWorktree`. The places that turn an ID back into a path use a lookup or
  the codec.
- Matching a cwd to a worktree (`WorktreeDirectoryIndex`, the `prowl open` resolver) keys on
  the location. Remote paths never pass through `PathPolicy` (local `stat` and symlinks).

### Capabilities (D3)

`Repository.Capabilities` grows a location dimension and reasons:
`availability(_ feature:, kind:, location:) -> available | unavailable(reason)`, with
cached facts (remote tools: git, bash; local tools: `gh`) kept apart from runtime
reachability. Features added to the existing eight: diff window, external diff, line counts,
icon detection, open in editor, Finder, workspace, archive script, clone, and Profile launch
(until 082 L1f; enforced at the shared launch boundary in `AppFeature+AgentProfiles.swift`
and for direct terminal commands, so a remote target gets neither a local Profile surface
nor a remote launcher). Views disable
controls with the reason as tooltip; the command palette filters; the same check runs at the
reducer and admission boundary. Raw `kind == .plain` checks that express identity ("a plain
folder is its own worktree") stay as they are. This slice lands before the host boundary, so
the host protocol only covers operations a remote folder can do.

### Host boundary

`RepositoryHost` exposes operations, not mechanisms. `GitClient` takes its executor from the
host (`GitClient(executor:)`); the ad-hoc instances and the bypasses of G3 route through it
or sit behind a capability. The six cwd-inferred `gh` calls get an explicit target that
keeps the code host (`[HOST/]OWNER/REPO`, as `repoArgument` in `GithubCLIClient.swift`
already builds for enterprise hosts), resolved once through the host: positional for the two
`gh repo view` calls (which have no `--repo` flag), `--repo` for the four `gh run` calls. `gh`
then runs locally without a repository cwd, so a host without `gh` keeps PR status. Tests
assert the arguments of all six calls, including a non-github.com host. The local host keeps the fast paths: direct reads of `HEAD`, `index.lock`,
the index header that sets watcher timing, local untracked line counts, creation times, and
the move-then-prune worktree removal. `observeChanges` wraps the five local monitor roles
(four classes in `WorktreeInfoMonitors.swift`) into one host stream that keeps today's six watcher events;
cadence logic stays in `WorktreeInfoWatcherManager`.

### Remote command lane

`RemoteConnectionOwner` gets a command lane next to the probe lane, on the same shared
connection (`ConnectionKey`, private `ControlPath`):

- A general `run(RemoteShellCommand)` with its own deadline and output budget (the 5 s and
  256 KiB probe limits are too small for `wt ls` and polling).
- Line streaming for worktree creation; a bundled script with arguments sent as
  `bash -s -- <args>` on stdin (the `wt` script is bash 3.2 compatible and branches on
  `uname` for copies).
- The remote login PATH for user tools, as `GitExecutableResolver` does locally.
- Folder users take leases from the existing `RemoteConnectionRegistry` (no parallel
  ownership), so the folder lane and L0 panes share one connection and `-O exit` still runs
  only on the last release.

### Persistence (D6, D8)

- Host profiles persist in `~/.prowl/hosts.json` (`HostProfile` from
  `SSHConnectionRecipe.swift`, today without a store or caller), with the rebind state of C1.
- `PersistedRepositoryEntry` gains an optional host. A remote entry stores the encoded ID in
  `path`. Running an older app build on these files is out of scope (decided 2026-10-22).
- Load failures no longer prune pins or `prowlCreatedWorktreeIDs` (P0). An unreachable host
  makes a remote repository fail to load, so the feature itself needs this guard.
- ID and entry-path normalizers go through the codec (A2–A3). Today, loading rewrites pinned
  IDs through `PathPolicy.normalizePath`, which prepends the home directory to a
  non-absolute string (`RepositoryPersistenceKeys.swift`), and a `.plain` entry loads without
  an existence check (`RepositoriesFeature+RepositoryLoading.swift`). Remote IDs and entries
  must bypass both.
- The snapshot cache moves to version 3 and skips a single entry instead of dropping the
  snapshot; remote entries skip the `fileExists` check.
- The repository settings directory key includes the location, which also fixes today's
  basename collision. Migration copies (never moves) the old directory, because two
  repositories may share it.
- The other ID-keyed stores (order, archived, collapsed, last focused, recency, appearance,
  terminal states) need no format change: the encoded ID keeps them apart. The workflow
  history `rootKey` (`WorkflowHistoryStorage.swift`, local `realpath`) includes the host.

### Remote refresh (D4)

One batched command per remote repository returns: HEAD and branch per worktree,
`git diff --numstat HEAD` (tracked additions and deletions), the untracked file count, the
worktree list, worktree creation times, a hash of the remote URLs, and `isBare`. The row
shows tracked line counts and the untracked file count; the tooltip says that untracked
lines are not counted. The focused worktree polls faster than background ones. A failed
poll keeps the last state and shows the host as unreachable.

### Consent (D2)

Adding a remote folder is consent for that `HostProfile`: the add sheet says that Prowl keeps
a background connection to the host. The answer is stored per profile and is independent of
the L0 setting `GlobalSettings.remoteAgentDetection`, which keeps governing manual `ssh`.
Panes that Prowl opens for a remote folder get agent detection without the L0 panel.
`PROWL_REMOTE_AGENT_DETECTION=0` remains the kill switch for every side-channel connection.
The toolbar side-channel status also shows folder connections.

### Add flow (D7)

"Add Remote Folder…" sits in `AddToProwlView`, the menu and the command palette, behind
`PROWL_REMOTE_FOLDERS=1` until remote tabs, splits and restore all work (slice C5 turns it
on). Steps: host
(existing profile or new destination), path, validation on the side channel (`ssh -G`,
connect, `pwd -P`, `git rev-parse`), store. A new action carries the location; the local
entry points keep `.openRepositories([URL])`. An unreachable host stays listed as
unavailable. Removing a host profile or repository states what happens to its data.

### Terminals (D5)

- Prowl stages a launcher on the host over the side channel (mode 0600 files that remove
  themselves). The pane gets one typed line, `ssh -t <recipe> -- exec sh <path>`, with only
  safe characters, so the payload arrives byte for byte and no authentication prompt can
  read it. When ssh ends, the pane returns to a local shell with the L0 ssh-ended marker.
- The launcher is a POSIX `sh` bootstrap. It sets the cwd, the worktree environment (remote
  `PROWL_WORKTREE_PATH`/`PROWL_ROOT_PATH`) and `LC_PROWL_PANE`, then `exec`s the remote
  user's interactive login shell. A setup, run or custom script runs as that shell's first
  command, injected per shell while the user's own startup files load exactly once:
  - zsh: a `ZDOTDIR` wrapper that restores the user's `ZDOTDIR` and sources their files.
  - bash: `bash --noprofile --rcfile <wrapper> -i`, an interactive non-login shell. The
    wrapper sources the login startup files itself (`/etc/profile`, then the first of
    `~/.bash_profile`, `~/.bash_login`, `~/.profile`), then runs the first command. A login
    bash ignores `--rcfile`, and the `--posix -l` + `ENV` route of Ghostty's bash
    integration (`ThirdParty/ghostty/src/shell-integration/bash/ghostty.bash`) does not run
    `ENV` on macOS bash 3.2. The cost: `shopt login_shell` is off and `~/.bash_logout` does
    not run.
  - fish: `--init-command`, which runs after the user's configuration.

  Each wrapper clears its injection variables before the first command, so nested shells
  never replay it. This matches local behaviour, where the script is typed into the
  user's shell: the user's shell syntax, state such as `cd` or an activated virtual
  environment that stays, and a tab that stays open. A tab without a script is the same
  handoff with no first command. An unknown shell falls back to `"$SHELL" -i -c <script>` and then
  `exec "$SHELL" -l`, without the persistent state.
- Completion. Locally, custom command success, Close on Success and CLI command waiters run
  on `GHOSTTY_ACTION_COMMAND_FINISHED` (`handleCommandFinished` in
  `WorktreeTerminalState+Notifications.swift`), which the local shell integration produces
  with OSC 133. A remote host has no shell integration. So the wrapper reports the first
  command's exit status itself, with a marker that carries a per-launch nonce and passes
  through ssh. The surface maps a marker with the matching nonce to `handleCommandFinished`
  once. For a remote launch, the outer `ssh` command finishing never counts as script
  completion, so a later successful ssh exit cannot report a failed script as success. The
  marker format (an OSC 7501 extension or framed OSC 133) is chosen in C3.
- The surface records `RemoteLaunchOrigin(hostProfileID)`. The tracker uses the stored recipe
  instead of parsing argv and skips the consent panel; the label shows the profile alias.
  `SSHInvocation` already treats `-t` and a trailing command as supported.
- `RemotePaneTracker` exposes the foreground cwd of the pane's session from the latest
  snapshot. A split asks for a fresh probe, then falls back to the last known cwd, then to
  the worktree root. Agent entries use this cwd for remote origins, which also fixes the
  local cwd that L0 reports for manual remote agents.
- The layout snapshot leaf (`TerminalLayoutSnapshotPayload`) gains an optional origin (host
  profile and remote cwd). Restore reconnects with a plain shell launcher; it never reruns a
  script.

### CLI and Mirror

`ListCommandPayload` worktrees gain an additive `host` object (`profile_id`, `label`).
`prowl open <path>` resolves local worktrees only. Mirror needs no protocol change: the
encoded ID keeps remote worktrees distinct.

## Slices and PRs

Slices A1–A7 change nothing for local repositories; P0 only stops pruning on load failure.
B slices add unused code. C1–C4 stay behind
`PROWL_REMOTE_FOLDERS`; C5 turns it on, because before C4 a split of a remote pane opens a
local shell and before C5 a restored remote leaf would come back as a local shell.

| Slice | Content | Behaviour change |
| --- | --- | --- |
| P0 | Load failures do not prune pins or `prowlCreatedWorktreeIDs` (independent fix from `main`) | Pins survive an unavailable repository |
| A1 | One `Repository.terminalWorktree`; ID → path reversals become lookups | None |
| A2 | `RepositoryLocation`, the ID codec (normalizers keep non-local IDs unchanged), `localURL`, `.local` initializers, deprecated forwards | None |
| A3 | Call-site migration by category: identity and settings keys (with the basename fix and copy migration), git and file reads, terminal cwd and cwd matching, CLI; then delete the forwards. Two or three PRs | Settings directory key changes (migrated) |
| A4 | Capabilities with location and reasons (including Profile launch), enforced at the reducer, launch and admission boundary | None |
| A5 | `GitClient(executor:)`, ad-hoc instances and bypasses routed, `gh --repo` | None |
| A6 | Repository state reads and `observeChanges` as host operations; local fast paths kept | None |
| A7 | Typed environment in `AgentProfileLaunchPlan`, rendered to the same `terminalInput` (prepares 082 L1f; can run in parallel) | None |
| B1 | Command lane, budgets, streaming, `bash -s` scripts, folder leases on the existing registry | None (unused) |
| B2 | `hosts.json`, remote entries, snapshot v3 per entry | None (unused) |
| B3 | `RemoteRepositoryHost` and the batched refresh, parser tested with recorded output | None (unused) |
| C1 | Add Remote Folder, per-profile consent, rebind prompt, unreachable state | Behind the flag |
| C2 | CLI and Mirror `host` field, local-only `prowl open`, `alias:/path` selector, workflow `rootKey` | Behind the flag |
| C3 | Launcher with per-shell handoff and completion marker, remote tabs and scripts, `RemoteLaunchOrigin` | Behind the flag |
| C4 | Tracker cwd accessor, remote splits, remote agent cwd | Behind the flag |
| C5 | Snapshot origin, reconnect on restore, `docs/` update; flag on | Remote folders ship |

## Acceptance criteria

082 L1-1 to L1-7 apply as written. In addition:

| Id | Criterion |
| --- | --- |
| R-1 | The ID codec round-trips hostile paths (spaces, `%`, `#`, `:`, Unicode); local IDs are byte-identical to today's |
| R-2 | Remote git and plain entries (with their host field) and remote pins survive load, save and an unreachable host unchanged; no normalizer turns a remote ID into a local path |
| R-7 | A linked local worktree keeps distinct `workingDirectory` and `repositoryRootURL`, `isMain == false`, and both script environment paths through A2 |
| R-8 | A remote target gets no Profile launch (UI disabled with a reason, refused at the launch boundary); the same Profile still launches locally |
| R-9 | At the slice that turns the flag on, a restart with mixed local and remote tabs restores no remote leaf as a local shell and replays no script |
| R-3 | A remote folder opens no connection before it is added; with L0 `disabled`, its panes still detect agents; `PROWL_REMOTE_AGENT_DETECTION=0` stops all side-channel connections |
| R-4 | With bash 3.2, bash 5, zsh and fish as the remote login shell: setup, run and custom scripts arrive byte for byte and run in that shell (a shell-specific payload succeeds, for example zsh `${(U)value}`); the login startup files load exactly once; a `cd` or `source` in the script persists at the prompt; a nested shell does not replay it; a tab without a script stays connected at the requested cwd; no authentication prompt receives script text |
| R-10 | On a host without shell integration: a custom command `true` with Close on Success closes its pane; `false` stays open with failure; the success notice fires once; a CLI command waiter completes while the remote shell stays connected; a later ssh exit after a failed script reports no success |
| R-5 | Remote dirty state shows tracked line counts and the untracked file count within one polling interval |
| R-6 | Every A slice keeps the existing test suite green and local watcher timing unchanged |

## Alternatives & decisions

| Decision | Chosen | Rejected |
| --- | --- | --- |
| D1 Remote ID (2026-10-22) | `ssh:<uuid>:<path>`, ID = encoded location, one codec | Any ID that does not start with `/` (not self-describing); `remote:` prefix (reads as a git remote); `prowl-ssh://` URI (invites `URL(string:)`, breaks raw paths); a struct ID type (doubles the churn; possible later) |
| D2 Consent (2026-10-22) | Adding a folder is consent for its host profile, independent of the L0 setting | Folder panes still obey the L0 setting (a connected folder without agents); a global `enabled` as precondition (binds two different choices) |
| D3 Order (2026-10-22) | Capabilities before the host boundary | Host boundary first (a larger protocol that shrinks later) |
| D4 Remote dirty (2026-10-22) | Tracked line counts plus untracked file count | Untracked line counts on the host (unbounded cost per poll); dirty flag only (a different row and a new UI state) |
| D5 Remote launch (2026-10-22) | Launcher staged over the side channel, one typed `ssh -t` line | Base64 payload on the ssh command line (blob in scrollback, `base64 -d/-D`, outer quoting); typed follow-up input (a prompt can read it, and if ssh fails the local shell runs it) |
| D5a Script shell (2026-10-22, from review) | POSIX bootstrap, then the user's interactive login shell runs the script as its first command (zsh `ZDOTDIR`, bash `--rcfile` on a non-login interactive shell that replays the login files, fish `--init-command`), with its own completion marker | `"$SHELL" -i -c` then handoff (script state does not persist; kept as the fallback for unknown shells); POSIX `sh` only (users must write POSIX scripts) |
| D6 Remote entries (2026-10-22) | Optional host on `PersistedRepositoryEntry`, encoded ID in `path`; running an older app build is out of scope | A separate `remote-repositories.json` (safe for older builds, but two sources to merge) |
| D7 Exposure (2026-10-22; moved from C3 to C5 in review) | `PROWL_REMOTE_FOLDERS` until C5 | Visible on merge (a folder without terminals); flag on at C3 (splits open local shells and restore loses remote leaves until C4–C5) |
| D8 Found bugs (2026-10-22) | Pin prune guard now (P0); basename collision with the settings key change in A3 | Both independent now (key scheme decided early); both inside L1 slices (the prune bug stays longer) |

## Open questions

- Polling intervals for focused and background remote worktrees, and backoff while the host
  is unreachable.
- Close confirmation: Ghostty reports a live process while `ssh` runs, so every remote pane
  asks before it closes.
- Launcher location (`$TMPDIR` or `~/.cache/prowl`) and cleanup when ssh never runs it.
- Completion marker format, and whether framed OSC 133 inside the outer `ssh` command
  confuses Ghostty's prompt tracking for the local shell.
- Where `wt` puts remote worktrees (the worktree base directory setting is a local path).
- Rebind UI for a changed `HostName`, and the behaviour of the folder lane while paused.

## Amendments

- Updated 2026-10-22: A1 landed (`Repository.terminalWorktree`; ID → path reversals with a model become lookups; the rest is listed for A2–A3) — see [003-a1-terminal-worktree.md](003-a1-terminal-worktree.md)
- Updated 2026-10-22: A2 landed (`RepositoryLocation`, the ID codec, location-backed models with local forwards, ID normalizers that keep non-local IDs) — see [004-a2-location-codec.md](004-a2-location-codec.md)
