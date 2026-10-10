# 080 — Neutral User Settings Paths: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-10 | Rename user settings, retain ordered legacy reads, and add non-destructive migration with strict error handling | Issue #751 |

## Outcome & current state (as of 2026-10-10)

- `App/Sources/Support/ProwlPaths.swift` uses `global.user.json` and
  `prowl.user.json`. Repository fallback checks `prowl.onevcat.json` before the
  existing pre-rebrand filename. No new repository-root fallback was added.
- `App/Sources/Features/Settings/BusinessLogic/UserSettingsFile.swift` shares the
  load/save policy between the two user settings keys. Only a confirmed missing
  file permits fallback. Existing invalid JSON, permission errors, dangling links,
  and link cycles stop the operation. A lock protects persistence operations and
  the failed-load state; saves remain blocked until a successful explicit reload.
- `App/Sources/Features/Settings/BusinessLogic/SymlinkPreservingFileWriter.swift`
  adds exclusive creation. Regular-file migration publishes a complete `0600`
  temporary file with `link(2)`, which refuses an existing destination, then removes
  the temporary name. This does not hard-link the old settings file. Existing
  replacement writes still use `rename(2)`.
- Migration copies the original validated bytes, including unknown fields. A
  legacy symlink creates a new link to its resolved target, preserving dotfiles
  storage. Old regular files remain migration-time snapshots; there is no dual
  write, downgrade synchronization, automatic deletion, or legacy-read expiry.
- The shared settings keys capture their storage dependencies at initialization
  and retain one persistence instance. This keeps the failed-load guard alive
  through later automatic saves. Test stores now use the standard missing-file
  error instead of a test-only error with ambiguous meaning.
- `docs/reference/settings-fields.md` documents migration, recovery, and downgrade
  behavior. The related settings, profiles, custom-actions, and concepts pages
  use the new paths.

## Verification

- The first migration tests failed against the previous implementation, then
  passed after implementation. A second red/green cycle covered a repaired disk
  file after a failed load: automatic saves must stay blocked until reload.
- 146 affected app tests passed, including migration, file creation, symlink
  writer, settings keys, Profiles, Custom Commands, and Workflow Start suites.
- `make check` passed, including 235 script tests, formatting, lint, workflow and
  legacy naming checks, and the string catalog check.
- `make build-app` passed without warnings. No live UI or performance verification
  was needed for this storage-only change.

## Deviations from plan

None. The failed-load guard also covers transient errors that clear before an
explicit reload; a save-time disk check alone is insufficient for that case.

## Open questions

None. Simultaneous configuration edits by separate Prowl versions remain outside
the synchronization contract; exclusive migration publication prevents replacing
an existing destination but does not add cross-process settings merge logic.
