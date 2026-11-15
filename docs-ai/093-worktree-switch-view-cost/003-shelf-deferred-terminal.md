# 093.003 — Shelf Mounts the Terminal After the Book Movement

## Context

On a Shelf book switch, the spines start to move only after the first update commits. That
update also builds and lays out the new book's terminal view, so the first frame came about
110 ms after the selection (Debug; about 100 ms with `-O`).

## Change

`ShelfView` keeps `mountedBookID`. When the open book changes, the open area shows the
terminal background color (`WorktreeTerminalManager.surfaceBackgroundColor()` at the surface
opacity) while the spines move, and `ShelfOpenBookView` mounts after
`ShelfMetrics.bookSwitchDuration` (0.2 s, the duration of the movement). The first book after
Shelf appears mounts at once. A newer switch cancels the wait, so quick switches mount only
the last book. The terminal takes focus when it mounts, so keys typed during the movement do
not reach it.

Hitch traces (Animation Hitches + Points of Interest, Debug, 16 worktrees, 30 switches, two
runs each):

| | Before | After |
| --- | ---: | ---: |
| First commit after the selection, median | 109–115 ms | 61–62 ms |
| First commit, p90 | 129–139 ms | 76–83 ms |
| Longest hitch | 117–167 ms | 50 ms |

Each switch still has one hitch of 33–50 ms when the terminal mounts. Mounting 50 ms after
the movement made it worse (four to five hitches per switch), so the mount stays at the end
of the movement.

## Refs

PR (fill in)
