# 084.026 — Unreachable state, rebind and removal (C1b)

## Context

C1a ([025](025-c1a-add-remote-folder.md)) adds remote folders. B3e and B3f
([023](023-b3e-load-through-host.md), [024](024-b3f-refresh-cadence.md)) mark a host that
does not answer, but nothing shows the mark. A host profile whose SSH configuration now
reaches another user, host or port stops every command (`RemoteRepositoryHostError
.authorityChanged`, B3b), and the plan leaves "Rebind UI for a changed `HostName`, and the
behaviour of the folder lane while paused" open. The add flow (D7) also says that removing
a host profile or a repository states what happens to its data.

## Change

All of it is behind `PROWL_REMOTE_FOLDERS=1`, like C1a.

### Host state

- The mark is per host profile (`rebindHostProfileIDs`), because every folder of a host
  shares its profile and its authority check:
  - a load or a poll that fails with `authorityChanged` adds the host;
  - a successful poll, or a load or poll that fails after the authority check (no answer,
    a git error), removes it;
  - a failure before the authority check (`ssh -G` rejects the configuration, the kill
    switch, a missing host profile or bundled script) leaves the mark as it is
    (`RemoteAuthorityCheck.unknown`), because it says nothing about the target. A
    configuration that is wrong for a moment therefore cannot clear the mark while no hold
    can start;
  - a failure that the sidebar reads back from state (`currentLoadFailures`) is `.unknown`
    too;
  - the rebind removes it.

  Restarting a hold is best effort. If the SSH configuration changes again between a poll
  that passed the authority check and the hold that follows it, `holdConnection` finds the
  changed target and holds nothing. That folder then has no hold until the next change of
  its host's mark or a rebind. The polls still run; each command opens its own connection.
  Removing a folder needs no cleanup. A remote plain folder is not polled: when the SSH
  configuration is put back, its row clears through Rebind Host, which then offers Connect
  Again.
- When a load or poll newly marks a host, the connection holds of its folders end
  (`releaseConnectionHolds`): they hold a connection to the old target. Other hosts keep
  theirs, and so do other users of the connection (L0 panes hold their own leases). The
  rebind starts the holds again, and so does a load or poll that clears the mark (the
  configuration reaches the bound target again), so the polls share one connection again
  (`markRebind`, `connectionHoldEffects`).
- `State.remoteHostStatus(for:)` gives the sidebar state of a remote folder:
  `.needsRebind(hostProfileID)` before `.unreachable`, and nil for a host that answers or
  a local repository.

### Sidebar

- A folder that failed to load shows `alias:/path` (D1 display form) and its reason: "The
  host did not answer", or "The SSH configuration changed" with a Rebind Host button.
  Retry and Remove Repository stay.
- A loaded folder keeps its last state (B3f) and shows a badge in its header: a
  `network.slash` image with a tooltip for a host that did not answer, or a Rebind Host
  button for a changed configuration.

### Rebind (answers the open question)

1. Rebind Host resolves the profile's recipe again (`RemoteRepositoryHostClient
   .resolveTarget`, `ssh -G`).
2. A prompt names both targets: "The SSH configuration of mini now reaches
   dev@new:2222. Its folders were added for dev@mini.local. Prowl does not connect to
   mini until you use the new target." The buttons are Use the New Target and Cancel.
   When the configuration reaches the bound target again, the prompt offers Connect
   Again instead.
3. Use the New Target stores the new `connectionKey` in `~/.prowl/hosts.json` in an
   effect, with B2b's compare and swap:
   - a file that changed since it was loaded is read again, and the key is set on it;
   - a save that still fails puts the old key back in memory at once, so no command uses an
     unsaved target, reloads the file, and shows the reason (`HostProfilesFileError` now has
     messages).
4. Then the host's mark is cleared, and for each polled folder of the host: a poll in
   flight with the old target is cancelled, the backoff ends, the connection hold starts
   again (`connectionHold`, which B3f skipped for a changed target), and a poll runs at
   once. A reload loads the folders that failed.

While a profile waits for a rebind, every command on its folders fails at once in the
leased lane's authority check, before `ssh` connects. There is no connection hold. Polls
keep their backoff. There is no "keep the old target": the recipe resolves through
`~/.ssh/config`, so the old target cannot be reached without editing that file.
Cancel leaves the folders paused.

### Rebind in the add sheet

A host can need a rebind with no folder to show it: its last folder was removed, or it
has only plain folders, which are not polled. The add sheet therefore offers the rebind
too. When the check finds that a known host now reaches another target
(`RemoteFolderValidationError.authorityChanged(profile, resolved:)`), the sheet names both
targets and shows **Use the New Target**. It stores the new target (the same
`storeHostTarget` as the sidebar's rebind), tells the sidebar (`.hostRebound`, which runs
`remoteHostRebound` for the host's other folders), and checks the folder again.

### Removal

- Removing a remote folder, from its section or from its failed row, says: "This removes
  the folder from Prowl. Its worktrees and
  files on mini stay as they are, and Prowl stops connecting to mini for it. mini stays
  in the host list." (`RepositoriesFeature.removalMessage(for:)`). A failed remote row asks
  first (`requestRemoveFailedRepository`); a failed local row is removed at once, as before.
  A local repository keeps its message.
- The host profile stays in `hosts.json` after its last folder goes. The add sheet offers
  it again, and with no folder there is no connection. There is no UI that removes a host
  profile yet, so there is nothing else to state.

## Tests

`RemoteHostRebindTests`:

- a load with a changed target marks the folder and its host, and the failed row offers the
  rebind (checked red without the load classification);
- an unreachable host shows as unreachable with `alias:/path`;
- a poll with a changed target marks the host until a poll without it;
- a failure for another reason clears the host's mark;
- a rebind shows the prompt, stores the new target in `hosts.json`, ends the backoff,
  starts the hold again, polls and reloads (checked red without the store);
- a rebind keeps a host that another process added to `hosts.json`, and an unreadable file
  is not written and stops the rebind with its reason. In this test the shared value reads
  the changed file before the save, so the reload-and-retry branch itself does not run;
  it is the same as the add flow's;
- each failure before the authority check is `.unknown`, and a timeout or a missing `git`
  passed it;
- the prompt names both targets; `ConnectionKey.displayName` shows a port other than 22;
- the add sheet rebinds a changed known host, stores the new target and adds the folder;
- a changed target found by a poll or a load ends the holds on that host, another host
  keeps its hold, a rejected configuration keeps the mark (checked red), and a poll that
  clears the mark holds the connection again (checked red; a one-minute time limit turns a hold that never ends
  into a failure);
- a failed remote row asks before removal, and a failed local row is removed at once
  (checked red);
- the removal message of a remote folder says that its files and its host stay, and does
  not name a host profile that is missing.

The badge and the row are checked visually in C1c, with a real remote folder.
