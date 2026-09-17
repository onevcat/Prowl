# 067.008 — Create panes from the Mac client

## Status

Implemented, 2026-09-17. Local commits only until the user requests publication.

## Context

The Mac connection sheet can only mirror an existing pane. It also appends unstable
Tab N labels and has incomplete row hit targets. The user requested creation of a
Shell or Agent Profile pane in an existing worktree, followed by mirroring it.

## Approach

- Remove generated tab ordinals at the Host descriptor source; retain meaningful
  terminal/worktree names and split-pane distinctions.
- Make connection rows fully clickable and place Refresh Panes beside Cancel.
- Add a New Pane form with a worktree picker and Shell / Agent Profile choices.
  Reuse the mobile launch model and public CLI creation route where possible.
- Include known worktrees with no running terminal in the remote catalog using
  the same repository projection as CLI target resolution.
- Resolve tab creation from known worktrees without requiring an existing pane.
  Reject missing and ambiguous targets before creating a terminal.
- Advertise Shell creation separately from Profile creation. Existing clients
  continue to use their current Profile request shape.
- Create background tabs without changing the Host selection. Extend ordinary CLI
  background tab creation to support Shell; background split panes remain unchanged.
- Correlate commands by request ID, impose a deadline, and cancel local waiters on
  disconnect. An uncertain creation never automatically repeats. Keep that state
  while switching between the pane list and creation form.

## Validation

Host descriptor regression, command allowlist/deduplication, empty worktree catalog,
Shell and Profile creation, unavailable profiles, uncertain delivery, command timeout,
and cancellation. Native sheet checks cover full-row clicks and creation/recovery.
Run formatting/lint checks, relevant app tests, CLI checks, and the Debug app build.

## Outcome

The Mac sheet now provides full-row selection and a New Pane form for Shell and
Agent Profile creation. Both clients compile the launch model from
`MirrorClient/Shared/MirrorLaunchModel.swift`. Mac command requests have correlated
responses and a 30-second deadline. Creation uncertainty persists across form
navigation and catalog refreshes.

Native fixture checks confirmed whitespace clicks, the bottom action row,
Shell/Profile layouts, and an editable form after explicit rejection. No live Agent
service was invoked by these previews. Tests cover the public Host route separately.

Validation completed:

- Mirror model, command channel/service, Host, pairing, protocol, and label regression
  checks passed. The final 29-case lifecycle/App-router run also passed after the
  worktree-only creation fix; the existing Profile background-focus test passed.
- A real loopback Mac client created and subscribed to a Shell in a dormant worktree
  through Host and the App CLI router. Host worktree/tab selection stayed unchanged;
  the created surface did not need to be selected or mounted in a Host window first.
- iOS launch-model tests: 6 passed after sharing the model.
- CLI build and smoke checks passed; unit suite: 301 passed; integration suite: 105 passed.
- `make check` and `make build-app` passed. Some test builds reported existing
  dependency-scan warnings; the final Debug build had no warnings.
- Cross-device launch of a real external Agent was not manually exercised.
