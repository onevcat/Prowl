# 084 — SSH Remote Folders: Action Log

The outcome of [000-plan.md](000-plan.md) across its slices. Each slice has its own record
(`002`–`033`) with the code, the review rounds and the verification. This file is the
index and the state after the last slice (C5).

## Timeline

All dates are 2026. Each slice PR went through a Pi Reviewer review loop until clean.

| Date | Slice | PR | Record |
| --- | --- | --- | --- |
| 10-22 | Plan reviewed (5 rounds clean) | #952 | [000](000-plan.md) |
| 10-22 | P0: a load failure does not prune pins or created-worktree IDs (from `main`) | #954 | 002 (on its branch) |
| 10-22 | A1: one `Repository.terminalWorktree` | #955 | [003](003-a1-terminal-worktree.md) |
| 10-22 | A2: `RepositoryLocation`, the ID codec, `localURL` | #956 | [004](004-a2-location-codec.md) |
| 10-22 | A3a / A3b: identity and settings keys; terminal cwd and cwd matching | #958, #959 | [005](005-a3a-identity-and-settings-keys.md), [006](006-a3b-cwd-matching-cli.md) |
| 10-22 | A4a: capabilities with reasons, enforced at the boundaries | #960 | [007](007-a4a-capability-enforcement.md) |
| 10-22 | A5a / A5b: explicit `gh` repository; `GitClient(executor:)` | #961, #962 | [008](008-a5a-gh-repository-target.md), [009](009-a5b-git-executor.md) |
| 10-22 | A6a–A6e: `RepositoryHost`, watcher, settings and PRs by location; forwards deleted | #963–#967 | [010](010-a6a-repository-host.md)–[014](014-a6e-delete-forwards.md) |
| 10-22 | A7 (from `main`) | #968 | 015 (on its branch) |
| 10-23 | B1: the command lane on the shared connection | #969 | [016](016-b1-command-lane.md) |
| 10-23 | B2a / B2b: roots by location; host profiles and the snapshot | #970, #971 | [017](017-b2a-roots-by-location.md), [018](018-b2b-hosts-and-snapshot.md) |
| 10-23 | B3a–B3f: refresh parser, remote host, remote worktree creation, creation by location, load through the host, refresh cadence | #972–#977 | [019](019-b3a-refresh-parser.md)–[024](024-b3f-refresh-cadence.md) |
| 10-23 | C1a–C1c: Add Remote Folder behind the flag; unreachable and rebind; UI gates and toolbar status | #978–#980 | [025](025-c1a-add-remote-folder.md)–[027](027-c1c-ui-gates.md) |
| 10-23 | C2: `host` in the CLI, `label:path`, reachable refusals | #981 | [028](028-c2-cli-host.md) |
| 10-23 | C3a: the launcher, staging and the OSC 7501 completion marker; 5 review rounds | #982 | [029](029-c3a-remote-launcher.md) |
| 10-23 | C3b: remote tabs, `RemoteLaunchOrigin`, the typed `ssh` line; 3 review rounds | #983 | [030](030-c3b-remote-tabs.md) |
| 10-24 | C3c: remote scripts, Close on Success, waiters, CLI tabs; 3 review rounds | #984 | [031](031-c3c-remote-scripts.md) |
| 10-24 | C4: remote splits, the tracker's directory on the host, the remote agent directory; 3 review rounds | #985 | [032](032-c4-remote-splits.md) |
| 10-24 | C5: layout restore with remote leaves; remote folders on; user docs | this slice's PR | [033](033-c5-restore-and-flag.md) |

## Outcome & current state (after C5)

- **Identity.** A remote folder is a `RepositoryLocation.remote(hostProfileID:path:)` with
  the ID `ssh:<uuid>:<path>`. Local IDs are unchanged. Every caller decides by location
  and capability (`RepositoryFeature`). Nothing reverses an ID into a local path.
- **Host and consent.** Adding a folder stores a `HostProfile` (recipe, alias, bound
  authority) and is the consent for that host. One shared side-channel connection per host
  carries:
  - git state and refresh;
  - worktree creation;
  - launcher staging;
  - agent probes.

  An authority change pauses the folder until it is rebound. `PROWL_REMOTE_AGENT_DETECTION=0`
  stops every side-channel connection.
- **Terminals.**
  - A remote tab or split is a local pane that types
    ` /usr/bin/ssh -t <session overrides> <recipe> -- exec sh <launcher>`. The launcher hands
    over to the user's login shell; startup files load once.
  - A script runs on the host as the first command and reports its status with an OSC 7501
    marker. The outer `ssh`'s finish never completes a script.
  - Splits start where the anchor is on the host.
  - The layout saves remote leaves and restores them as plain remote panes.
- **Agents.**
  - Remote panes need no consent, use the stored recipe, and show the host alias.
  - A remote agent's directory is the host's. It resolves only to its own remote folder,
    on the same host.
- **Exposure.** Remote folders are on. `PROWL_REMOTE_FOLDERS=0` hides them and keeps stored
  ones.

## Verification

- **Each slice:** `make check`, `make build-app` and the full `make test` (4500+ app tests).
  CLI slices also ran the CLI suites.
- **Tests that run real processes:**
  - real shells: zsh, bash 3.2, bash 5, and fish where installed;
  - a Debian image with fish, bash, zsh and dash (`TEST_RUNNER_PROWL_LAUNCHER_DOCKER_IMAGE`);
  - a real host (`TEST_RUNNER_PROWL_REMOTE_LANE_HOST=mini`).
- **E2E in isolated Debug instances against `mini`:**
  - the add flow, status and rebind (C1);
  - the CLI host field (C2);
  - remote tabs, agents, Undo and ⌘T (C3b);
  - CLI tabs with host paths and the missing-folder path (C3c);
  - a split that follows its anchor's directory (C4);
  - restore (C5).

  Screenshots are on the PRs. The screen was locked for the C3c–C5 runs, so those used the
  CLI only.

## Open items

- **macOS hosts.** A plain shell session (a system binary) cannot be matched to its pane:
  the agent status says "Agents not detected", and splits start in the folder. Agents,
  Homebrew shells and tmux sessions match.
- **CLI waits.** `prowl send --wait` into a remote pane needs the host shell's OSC 133;
  otherwise use `--no-wait`.
- **In Place custom commands** stay refused in remote folders.
- **Not built for remote folders:** remote workflows, including the host-aware workflow
  `rootKey` (C2 deferred it), and Agent Profile launches (082 L1f).
- **Restore at launch.** An unreachable host gives one "did not start" toast per remote pane.
