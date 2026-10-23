# 084.025 — Add Remote Folder (C1a)

## Context

After B3 ([019](019-b3a-refresh-parser.md)–[024](024-b3f-refresh-cadence.md)), a remote folder
can load, refresh and create worktrees on its host, but nothing can add one. The plan's
"Add flow (D7)" and "Consent (D2)" sections describe the entry points, the steps and the
consent. C1 also owns the rebind prompt, the unreachable state and the A4b UI gates. That
is three changes, so C1 is three PRs:

- **C1a (this record):** the flag, the Add Remote Folder sheet, validation on the host,
  the stored host profile and entry, and the consent text.
- **C1b:** the unreachable state in the sidebar; the rebind prompt for a changed `HostName`,
  which also restarts the connection holds (B3f); what removing a host profile or a
  repository does to its data.
- **C1c:** the A4b UI gates (disabled controls with the reason as tooltip, palette
  filtering, Finder and copy-path actions through the reducer) and the toolbar
  side-channel status for folder connections, with a visual check on a real remote folder.

## Change

Everything is behind `PROWL_REMOTE_FOLDERS=1`. Without it, nothing changes. Views read
`RemoteFolders.isEnabledInThisProcess`, which reads the environment once. Reducers read the
`RemoteFoldersEnabledKey` dependency, so tests can turn the flag on.

### Entry points

"Add Remote Folder…" appears in three places:
- the Add to Prowl popover, as a "Remote…" button next to Browse and Clone;
- the repository menu, next to New Workspace;
- the command palette.

Each one sends `addRemoteFolderRequested`, which opens the sheet only while the flag is on.
The local entry points keep `openRepositories([URL])`.

### The sheet (`AddRemoteFolderFeature`, `AddRemoteFolderView`)

- **Host.** The known host profiles from `hosts.json`; the newest is selected. "New Host…"
  shows a field for an `ssh` destination: `user@host`, or an alias from the SSH
  configuration.
- **Path.** A host path. `~` and a relative path resolve against the host's home, where
  `ssh` starts.
- **Consent (D2).** The sheet says that Prowl keeps a background SSH connection to the host
  while its folders are in the sidebar. Adding a folder is the consent for its host
  profile. Only this flow creates profiles, so a profile in `hosts.json` is a consented
  one. C3 reads it for the folder's panes.
- **Add** checks the host and the path, then closes the sheet and adds the folder. An error
  stays in the sheet with its reason.
- **While the check runs**, the fields, Cancel and Esc are disabled. The check stores a new
  host profile before it ends, so closing in between would leave a consented host without
  its folder.

### Validation (`RemoteFolderValidatorClient`)

1. **The side channel is on.** With `PROWL_REMOTE_AGENT_DETECTION=0`, the sheet says that
   remote connections are turned off. The check (`RemoteCommandLane.requireSideChannel`)
   also guards every leased command and connection hold. The kill switch therefore
   stops loads, polls and worktree creation of folders that are already listed, not only
   the add flow. The L0 consent setting does not apply to folders (D2).
2. **The SSH configuration resolves** (`ssh -G`, `RemoteConnectionRegistry.resolve`).
   - For an existing profile, a changed authority (another user, host name or port) is
     refused with its alias. C1b replaces this with the rebind prompt.
   - A new destination with the same recipe as a known profile reuses that profile
     (`knownProfile(for:resolvedTo:in:)`). When that profile's target changed, it is refused
     the same way: "New Host…" must not create a second profile with the same name.
3. **The host answers and the path is found.** `RemoteRepositoryHost.discoverFolder` runs one
   script on a leased lane:
   - a path in a repository adds the repository's main worktree: git's common directory is
     `<main>/.git`, so a subfolder or a linked worktree adds the main worktree, as the local
     flow does;
   - a bare repository adds itself, and a worktree of a bare repository adds the bare
     repository, as `wt root` finds it;
   - a folder that git says is not in a repository (`not a git repository`, read with
     `LC_ALL=C`), or any folder on a host without git, is added as a plain folder;
   - any other git error, such as `safe.directory`, is reported with git's message instead
     of adding a plain folder;
   - a root that is empty or not a canonical host path is refused, so the sheet never
     closes on a folder that the entry normalizer would then drop;
   - a path that does not exist, or cannot be entered, is refused with the path ("There is
     no folder at … on the host."). A path with a NUL byte cannot be used.
4. **A new host profile is stored** in `hosts.json` before the entry, so no entry refers to
   a host that the file lacks.
   - A file that changed since it was loaded is read again, and the profile is added to it
     (B2b's compare and swap).
   - A save that still fails reloads the list from the file and stops the add.
   - A `hosts.json` that this build cannot read is never written over (B2b). The sheet
     names the file instead of asking to try again.

### Adding

`repositoryManagement(.openRemoteRepository(location, kind:))` stores the entry
(`PersistedRepositoryEntry` with the encoded ID, B2b) and loads every repository, through
the same path as the local flow (`openEntries`, now shared). The new remote folder then
loads through its host (B3e) and joins the refresh cadence (B3f).

### Known cost

Each check runs `ssh -G` twice: once for the profile's key and once in the leased lane's
authority check. The lease ends when the check ends, so the load right after the add
connects again. Both are one-time costs of adding a folder.

## Tests

- `AddRemoteFolderFeatureTests`:
  - a new host is saved to `hosts.json` before the folder is added;
  - an existing host is offered first, and a failure shows its reason;
  - cancel closes the sheet, except while the check runs;
  - the sheet opens only while the flag is on, with the newest host selected;
  - a new destination matches a known host or needs a rebind;
  - the kill switch stops remote folder connections;
  - an added folder becomes an entry and loads; in tests, without a host connection, it
    stays listed as a load failure.
- `RemoteRepositoryHostTests`: on a real repository through the local lane, a main path, a
  subfolder and a linked worktree all find the main worktree. A worktree of a bare
  repository finds the bare repository. A plain folder is plain, a missing path is
  refused, and `~` is the home directory. Replies with a git error, an empty root and an
  inaccessible path give their errors.
- `CommandPaletteFeatureTests`: the palette's exhaustive kind lists include the new item.
- Against a real host (opt-in, `TEST_RUNNER_PROWL_REMOTE_LANE_HOST=<host>`):
  - `RemoteFolderValidatorLiveTests` runs the live check behind the Add button: `ssh -G`,
    the authority check, the leased lane and the discovery. A new destination makes a new
    profile; the same destination again, and the chosen profile, reuse it; a missing path is
    refused.
  - `aRealHostListsAndChangesWorktrees` also finds the main worktree from a linked worktree
    and the fixture's parent as a plain folder.

The sheet itself gets its visual check in C1c, with the other UI gates.
