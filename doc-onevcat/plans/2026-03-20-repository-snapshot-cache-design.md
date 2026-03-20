# Repository Snapshot Cache Design

## Goal

Add a small startup cache that restores repository UI immediately on app launch, while keeping live repository discovery as the only source of truth.

## Principles

- Keep the cache disposable.
- Keep the payload small and structural.
- Do not let bad cache data affect settings loading.
- Always run a normal live refresh after cache restore.
- Only overwrite the cache after a complete successful live load.

## Storage

Use a standalone JSON file at `~/.prowl/repository-snapshot.json`.

Reasoning:

- Cache decode failures stay isolated from `settings.json`.
- The file can be deleted safely with no migration burden.
- The payload can evolve with an explicit schema version.

## Payload

Persist only data needed for first paint:

- repositories in UI order
- repository root path
- repository display name
- worktree name
- worktree detail string
- worktree working-directory path
- worktree `createdAt`

Do not cache:

- PR state
- line changes
- watcher state
- notifications
- `lastFocusedRepositoryID`

Selection restoration continues to use existing `lastFocusedWorktreeID` persistence.

## Invalidation

Treat the cache as a miss when any of the following happens:

- file is missing or empty
- schema version mismatch
- JSON decode failure
- any cached repository root path no longer exists
- any cached worktree path no longer exists

When invalid, discard the cache file and continue with a normal live load.

## Startup Flow

1. Load pinned/archive/order/last-focused persisted state.
2. Load repository snapshot cache.
3. If snapshot exists, restore repositories into state immediately.
4. Mark initial load complete so the main UI renders.
5. Start the usual live repository loading flow.
6. Apply live results to the UI.
7. If the live load succeeds with no repository failures, overwrite the snapshot file.

## Refresh Rules

Overwrite the snapshot only after complete successful repository loads:

- initial startup refresh
- manual refresh
- other flows that end in a full successful repository snapshot

Do not overwrite the snapshot on partial or failed loads.

No TTL is needed because the cache is only a startup accelerator. Freshness comes from the unconditional live refresh that always runs after startup.
