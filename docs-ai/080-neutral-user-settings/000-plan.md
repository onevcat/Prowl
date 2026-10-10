# 080 — Neutral User Settings Paths: Plan

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-10-10 |
| **Primary PRs** | Pending |
| **Related** | Issue #751; [settings reference](../../docs/reference/settings-fields.md) |

## Background

The global and repository user settings filenames still contain `.onevcat.`.
These files now hold public product state, including profiles and workflow preferences.
The existing readers treat read and decode failures as missing data, which can replace
valuable configuration with defaults during a filename migration.

## Goals

- Use `global.user.json` and `prowl.user.json`, without changing the JSON schema.
- Retain old files and existing historical fallback paths.
- Preserve symlink-based dotfiles storage and owner-only permissions.
- Never replace unreadable or invalid configuration with defaults.

## Design / Approach

`ProwlPaths` supplies the new names and ordered legacy candidates. The two user
settings keys share a small persistence helper with injected storage operations.
Only a confirmed missing path permits the next candidate. A dangling symlink is
not a missing configuration file. Decode and permission failures stop loading.
Saves validate the selected disk data before writing. A failed load also blocks
saves on that shared-key instance until an explicit load succeeds, so automatic
profile seeding cannot persist defaults even if a transient read error clears.

On first load, validate legacy JSON and create the new file without replacing any
existing destination. Copy the original bytes rather than re-encoding them, so
unknown fields survive migration. A legacy symlink produces a new symlink to the
same resolved target. Plain files remain independent migration-time snapshots.
New regular files use the existing owner-only atomic writer machinery, extended
with exclusive publication. A failed migration reports an error and leaves the
source untouched. A later load can retry.

## Alternatives & decisions

- No destructive rename or automatic deletion: preserve a recovery source.
- No dual writes or merge logic: avoid divergent state and conflict policy.
- No downgrade synchronization guarantee: old versions use the old snapshot;
  symlink-backed files are an exception because both names share a target.
- No scheduled removal of legacy reads: users can skip releases.
- Do not add new repository-root fallback paths or change upstream settings.

## Verification

Test current/legacy precedence, byte-preserving migration, full model round trips,
missing files, decode and permission errors, failed creation, retry, and repeated
loads. Exercise real files for symlink targets (including relative links, broken
links and cycles), exclusive creation, and `0600` permissions. Run the affected
app test suites, `make check`, and `make build-app` before opening the PR.

## Amendments
