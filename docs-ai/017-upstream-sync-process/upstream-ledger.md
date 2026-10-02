# Fork Change Log

> Living document of entry 017. Migrated from `doc-onevcat/change-list.md` on 2026-07-12; update in place.

## Upstream Baseline

| Key | Value |
| --- | --- |
| Commit | `bcbc40599fa9e9180981993c20fb4ffa1c7479a1` |
| Tag | post-v0.10.5 |
| Date | 2026-07-06 |

All upstream changes up to and including this commit have been reviewed.
Future upstream checks should only inspect commits **after** this baseline.

---

## 2026-10-03 — Fork layout and names changed (074)

- The fork renamed the project from `supacode` to `Prowl` and moved the folders
  (`docs-ai/074-project-restructure-and-tuist/000-plan.md`). Upstream paths map as follows when a
  commit is ported: `supacode/…` → `App/Sources/…`, `supacodeTests/…` → `App/Tests/…`,
  `Resources/…` → `App/Resources/…`. The full table is in `docs-ai/README.md`.
- Like upstream, the fork now generates its Xcode projects with Tuist, but it keeps Xcode-native
  Swift packages (upstream uses `Tuist/Package.swift` and `.external`). The earlier decision to
  skip the upstream Tuist migration (2026-04-20) is replaced by entry 074; the upstream manifests
  are not ported.
- Entries below this one use the old paths.

---

## 2026-08-30 — Ghostty fork patch: lazy display link

- Added `a0671ce9` `Backport Ghostty lazy display link creation` to `onevcat/ghostty`
  `release/v1.3.1-patched` (backport of upstream `ghostty-org/ghostty#13639`, not yet in a tagged
  Ghostty release). New Ghostty surfaces no longer fail with `CREATE_FAILED` while the display is
  asleep; see `docs-ai/063-agent-workflows/009-display-sleep-surface-spike.md`.
- Prowl submodule bumped to that commit; prebuilt artifacts published as
  `xcframework-a0671ce9bf8a8e5ac8079021385adf2047462cc6-prowl-v1` and pinned in
  `scripts/ghosttykit-checksums.txt`. Drop the patch when upgrading past `a177ba90af`.

---

## 2026-07-12 — Ledger corrections (docs-ai backfill audit)

Verifying this ledger against GitHub during the docs-ai backfill (PR #558) surfaced four
bookkeeping errors, now corrected in place (marked *correction 2026-07-12* where inline):

- 2026-05-08 "Ported to Prowl PRs": #265 and #267 were in fact **closed unmerged**.
- 2026-06-09 table: `6fab2d28` is PR #416's merge commit (not #417's — that is `761ec204`),
  and `db2f39d0` belongs to PR #417, not #414. The #332 port is partial by design.
- 2026-04-20 deferred adoption of upstream #225 was never executed (status note added).
- Old Log: the snapshot cache is no longer "Pending upstream" — upstream #162 closed unmerged.

---

## 2026-07-09 — Review through post-v0.10.5

### Upstream changes reviewed

Reviewed 70 commits on `supabitapp/supacode` from `1d888dbc` (post-v0.10.2, 2026-06-05) through
`bcbc4059` (post-v0.10.5, 2026-07-06), spanning upstream releases v0.10.3 → v0.10.5. Per-commit
verdicts and decision rationale are recorded in
`docs-ai/017-upstream-sync-process/batch-2026-07-06-post-v0.10.5.md` (PR #547). The fork is now aligned to this
tip; the next `/check-upstream-changes` run only needs to diff against `bcbc4059`.

### Ported into the fork

| Upstream | Fork |
| --- | --- |
| `70786d2d` #410 / `82c101c1` #460 / `4e0aeb54` #482 / `ad4db32a` #535 — gh detection & login-shell hardening | PR #541 (`43625674`) |
| `3886a052` #447 Zed Preview / `c135b9d6` #496 IDEA EAP / `566bf4c4` #506 Nova open actions | PR #542 (`c1ead67f`) |
| `7a5c9ab1` #458 — Report the host app as TERM_PROGRAM | PR #543 (`ea9a1fd0`) |
| `99d27826` #478 — Preserve symlinked JSON config files on write | PR #544 (`c2708678`) |
| `ce03d3c3` #511 — Customizable notification sound picker | PR #545 (`199a9e2f`) |
| `f15420ce` #562 — Mute notifications for the viewed surface | PR #546 (`9d8ba6b1`) |

Fork adaptations worth noting: the sound picker defaults (and migrates legacy `true`) to the
fork's classic chime instead of upstream's Hero; the mute feature threads `isViewed` through the
event pipeline and treats canvas-managed surfaces as not-viewed (stale window flags would
otherwise silently drop notifications).

### Already present in the fork (no action)

Duplicate `WorktreeID` crash (#517), duplicate worktree paths (#480), terminal focus after
command palette closes (#566), Clone Repository flow (#524), terminal zoom memoization (#454),
Dismiss All popover (#409), build warnings (#513), GoLand/Rider/PhpStorm mappings — see the plan
doc for the per-commit equivalence table.

### Reviewed and skipped (decision recorded)

Window appearance rewrite + status inspector (#570/#577), keybinding conflict zone
(#459/#461/#416), OSC 3008 agent-presence track, toolchain self-diagnosis (#468), zmx track,
hook-driven agent integrations (Hermes/Kimi/Copilot CLI/OpenCode), upstream CLI socket acks
(#556), release/CI housekeeping, `c38c325d` #423 OpenTarget refactor (editor cases added in fork
shape instead), and a low-risk UI-polish list kept as future cherry candidates. Rationale for
each is in the plan doc.

### Deferred with tracking

- Searchable base-ref filter (`e37bebad` #387/#411) → Linear **CLAW-99** (fork approach captured
  in the issue).
- Remote SSH track (`88e50398` #407 + 6 follow-ups, ≈ +12k/−3.7k lines) → Linear **CLAW-98**
  (staged adoption options recorded).

---

## 2026-06-09 — Review through post-v0.10.2

### Upstream changes reviewed

Reviewed 55 commits on `supabitapp/supacode` from `5e88ec5d` (post-v0.8.5, 2026-05-05) through
`1d888dbc` (post-v0.10.2, 2026-06-05), spanning upstream releases v0.9.0 → v0.10.2. The fork is now
aligned to this tip; the next `/check-upstream-changes` run only needs to diff against `1d888dbc`.

### Ported into the fork

Equivalent behavior landed via dedicated fork PRs (fork implementations may differ to fit Prowl's
architecture):

| Upstream | Fork |
| --- | --- |
| `b1b65bf7` #378 — Tolerate login-shell noise in `gh` JSON output | PR #418 (`24027a91`) |
| `b1ecdf3d` #376 — Cap and coalesce terminal event streams | PR #416 (`2800fd0b`) |
| `974455b1` #347 — Coalesce OSC-9 progress to cut tab-bar lag | PR #415 (`7e0c9c76`) |
| `c0c1c2ac` #332 — Per-surface `@Observable` notification dot | PR #417 (`761ec204`) — partial: AnyView-erasure slice only; the per-surface dot mirror was deliberately skipped (fork's dot is already observed) |
| `955c1943` #329 / `be322039` #336 — Detail/menu-bar + split-tree perf (FocusedAction wrapper, drop AnyView erasure) | PR #414 (`c9f5100e`) / PR #417 (`db2f39d0`) |
| `65c87e30` #371 — Focus the terminal after worktree navigation | PR #419 (`e02c76f0`) |
| `fc4e4b0b` #353 — Selected command-palette row legibility | PR #420 (`3b499662`) |
| `66b300d1` #313 — Persist main window position and size | (`02e13192`, PR #420) |
| `3073482c` #352 — GitHub merge-queue state in PR popover/sidebar | PR #425 (`0b00ac62`) |
| `4abbe946` #351 — Override new worktree name and parent directory | PR #424 (`2acb948b`) |
| `813f44e3` #344 — Refresh hyperlink highlight on modifier press | PR #423 (`da8cfb39`) |
| `3ccd25a3` #310 — Sheet dismiss flash via TCA view-side APIs | PR #422 (`5f5393e2`) |

### Reviewed and skipped (architectural / not applicable)

- **zmx terminal-session persistence track** (`90b61140` #334, `4d50d48d` #360, `96392760` #368,
  `a536175f` #369, `f645bbf7` #356/#357, `b1e275a6` #361) — upstream moved terminal persistence onto a
  bundled `zmx` multiplexer. The fork keeps its own terminal-layout persistence and has no `zmx`
  dependency, so the whole track is skipped.
- **Hook-driven coding-agent integration** (`b47fee03` #307, `dfc5d6f6` #311, `7e3ddb98` #374 Kiro,
  `ac5d84c6` #317, `6fdfb3c8` #330) — relies on upstream's settings/hook modules that this fork does
  not carry.
- **Naming / appearance already diverged** (`a4a4457d` #312 capitalize "Supacode" → fork rebrands to
  Prowl; `4d07b0a5` #308 / `563e6913` #367 per-worktree title+color → fork uses its richer repo-level
  appearance model, consistent with the earlier #276 decision; `662b6eee` #321 terminal theme,
  `98b4cf1b` #320 repo·branch·worktree title, `c7891f9c` #305 custom-script color picker, `e6fd77ee`
  #358 Rename Branch → fork already ships equivalents).
- **Release housekeeping** — `bump v0.9.0`…`v0.10.2` tags do not apply (date-based fork releases).

### Not yet ported — re-evaluate next round

Reviewed but not carried over this round; candidates for future sync depending on need:
`1d888dbc` #381 (cross-fade shortcut hints), `4be71a58` #350 (worktree base-ref picker),
`0f02f7cb` #349 (stop sidebar shimmer when idle), `b69ce38e` #346 (re-surface archived worktrees
during delete), `b1b4c4f4` #345 (focus tab surface on tab-bar click), `9959f956` #340 (terminal flash
/ stuck pending worktrees), `7f1b2bb7` #339 (lock worktrees against prune), `19491fe1` #337
(split-zoom indicator), `861d70b7` #333 (freeze blocking-script tabs), `28e47c04` #331 (repo tag
truncation priority), `0b66caf5` #328 (Pinned/Active sidebar sections), `0a2548ca` #324 (nest sidebar
by branch + onboarding), `0a1ed578` #323 (sidebar perf/refresh), `9b62f0d5` #322 (folder/disabled-slot
hotkeys), `54cda551` #318 (split terminal File menu), `288d2f3f` #301 (window-layer terminal tint),
`31804471` #289/#306 (configurable Window-menu shortcut), `7700b841` #314 (`.inMemory` UserDefaults in
tests).

### Full upstream inventory (post-v0.8.5 → post-v0.10.2)

Flat list of all 49 non-release commits in range, for cross-reference:

- `1d888dbc` Cross-fade shortcut hints and drop the hold-to-reveal delay (#381)
- `b1b65bf7` Tolerate login-shell noise in GitHub CLI JSON output (#378)
- `b1ecdf3d` Cap and coalesce terminal event streams to reduce memory growth (#376)
- `7e3ddb98` Fix Kiro CLI version detection to use kiro-cli instead of kiro (#374)
- `96392760` Run surfaces under zmx via a Ghostty command-wrapper so shells keep full integration (#368)
- `65c87e30` Always focus the terminal after worktree navigation (#371)
- `a536175f` Persist terminal layouts incrementally and reap zmx sessions by attach state (#369)
- `563e6913` Collapse the new-worktree appearance section and mirror the title placeholder (#367)
- `4d07b0a5` Add per-worktree title and color customization (#308)
- `b1e275a6` Hydrate the Active sidebar section from persisted layouts on relaunch (#361)
- `4d50d48d` Build zmx as a universal macOS binary so Intel Macs can launch terminals (#360)
- `e6fd77ee` Add a Rename Branch sheet to the sidebar context menu and command palette (#358)
- `f645bbf7` Disable Ghostty auto shell-integration to fix terminal launch crash (#356) (#357)
- `fc4e4b0b` Improve the readability of the selected command palette row (#353)
- `3073482c` Show GitHub merge queue state in the PR popover and sidebar (#352)
- `4abbe946` Let users override the new worktree's name and parent directory (#351)
- `4be71a58` Let users pick the worktree base ref from local and remote branches (#350)
- `0f02f7cb` Stop the sidebar shimmer when an agent is awaiting input or idle (#349)
- `974455b1` Fix tab-bar progress lag and cut animation/re-render cost during agent activity (#347)
- `b69ce38e` Re-surface archived worktrees in the sidebar while their delete script runs (#346)
- `b1b4c4f4` Focus tab's focused surface on tab bar click (#345)
- `813f44e3` Refresh hyperlink highlight on modifier press without mouse move (#344)
- `90b61140` Persist terminal sessions across app launches with bundled zmx (#334)
- `9959f956` Fix terminal flash and stuck pending worktrees on sidebar selection (#340)
- `7f1b2bb7` Lock Supacode worktrees so prune can't drop them (#339)
- `19491fe1` Add split-zoom indicator button to tab bar (#337)
- `be322039` Observe trees dict so split-tree view re-renders on structural changes (#336)
- `861d70b7` Freeze blocking-script tabs after completion (#333)
- `c0c1c2ac` Move surface notification dot to per-surface @Observable state (#332)
- `28e47c04` Give repo tag truncation priority over trail in sidebar highlight subtitle (#331)
- `6fdfb3c8` Drop `ghostty +list-themes` reference from terminal theme toggle (#330)
- `955c1943` Detail-view + menu-bar performance: per-tab observation, snapshot caches, FocusedAction wrapper (#329)
- `0b66caf5` Highlight relevant sidebar rows with Pinned / Active sections (#328)
- `0a2548ca` Nest sidebar worktrees by branch with onboarding card (#324)
- `0a1ed578` Improve sidebar performance and refresh reliability (#323)
- `9b62f0d5` Fix worktree-selection hotkeys for folders and disabled slots (#322)
- `662b6eee` Add Supacode Terminal Theme toggle with glass background (#321)
- `98b4cf1b` Replace toolbar branch button with repo · branch · worktree title (#320)
- `54cda551` Add split terminal File menu, drop hover popover, mimic Ghostty's terminal commands (#318)
- `ac5d84c6` Fix `supacode settings repo` and add a per-repo Scripts subsection (#317)
- `7700b841` Use `.inMemory` UserDefaults in SidebarPersistenceMigratorTests (#314)
- `66b300d1` Persist window position and size across sessions (#313)
- `a4a4457d` Capitalize app name to Supacode in user-facing strings (#312)
- `dfc5d6f6` Auto-update agent integrations and collapse hooks to one per slot (#311)
- `3ccd25a3` Fix sheet dismiss flash by migrating to TCA 1.7 view-side APIs (#310)
- `b47fee03` Add hook-driven coding-agent presence + sidebar setup card (#307)
- `31804471` Make the Window-menu Supacode entry shortcut configurable (#289) (#306)
- `c7891f9c` Add global scripts and color picker for custom scripts (#305)
- `288d2f3f` Paint terminal tint at the window layer; keep chrome transparent (#301)

---

## 2026-05-09 — Ghostty fork patch

- Created `onevcat/ghostty` fork branch `release/v1.3.1-patched` from upstream tag `v1.3.1`.
- Added fork-only embedded C API `ghostty_surface_pid(ghostty_surface_t)` for per-pane agent process detection.
- Prowl submodule now tracks the patched fork branch. Upgrade procedure is documented in
  `docs-ai/007-ghostty-embedding-integration/ghostty-fork-sync.md`.

---

## 2026-05-08 — Review through post-v0.8.5

### Upstream changes reviewed

Reviewed 25 commits on `supabitapp/supacode` from `c4e9be3b` (v0.8.1, 2026-04-19) through
`5e88ec5d` (post-v0.8.5, 2026-05-05). Significant additions:

- **Ghostty key event routing** (`6c807c63`, #259; `539c0feb`, #264) — upstream fixed two
  `performKeyEquivalent` edge cases: only forward unmatched Ghostty bindings to a real main-menu item, and only
  consume keys from the actual first responder.
- **Repository and PR targeting** (`a4cdad9e`, #261) — resolves the GitHub PR owner/repo with `gh repo view`, which
  matters for fork clones whose remotes may point at different owners.
- **Notification, tab, focus, and window UX** (`072ad1e7`, #266; `6615f49c`, #269; `b34a66d5`, #279;
  `71dc4b57`, #295; `028ef412`, #297; `5e88ec5d`, #298) — upstream added jump-to-unread notifications,
  custom tab titles, worktree history, sidebar-to-terminal arrow focus, dynamic window titles, and main-window-only
  quit confirmation.
- **Sidebar/repository appearance and polish** (`4d19b068`, #260; `9bae228e`, #276; `3af3a164`, #258;
  `57e620a7`, #265; `514c3ceb`, #283) — dim inactive split panes, per-repo title/color, detail toolbar and loading
  state polish, sidebar animation CPU reductions, and script menu cache fixes.
- **Agent/editor/platform additions** (`943f3fab`, #245; `6fff0218`, #262; `650a6b52`, #292; `e06c07a0`) —
  Kiro and Pi agents, Android Studio editor support, and app icon bundle metadata.
- **Build/release housekeeping** (`92c7c461`, `644bd468`, `3b07571b`, `34da9417`, `bd9da925`, `4a8611d9`) —
  CI concurrency and upstream semantic version/build-number bumps.

### Decisions

- **Ported to Prowl PRs**: Ghostty key routing (#255), fork-aware PR repo resolution (#256), worktree history
  (#260), dynamic window title plus main-window quit behavior (#261), loading overlay polish (#262), sidebar animation
  CPU fix (#263), Android Studio editor support (#264), sidebar right-arrow focus (#265 — *correction 2026-07-12:
  closed unmerged after an LGTM review, never landed*), test workflow concurrency
  (#266), and `CFBundleIconName` metadata (#267 — *correction 2026-07-12: closed unmerged; Icon Composer not adopted*).
- **Reviewed and skipped**: Notifications UX (#266 upstream), inactive split dimming (#260 upstream), tab renaming
  (#269 upstream), and bare-repo detection (#263 upstream) were already covered, intentionally different, or not
  currently applicable in the fork.
- **Skipped due fork-specific architecture**: Repository title/color (#276 upstream) conflicts with Prowl's richer
  repository appearance model; Kiro/Pi agent hooks rely on upstream settings/hook modules not present in this fork;
  Run Script dropdown caching does not apply to Prowl's current popover/button implementation.
- **Skipped due fork release policy**: Upstream release-tip/warm-cache/inspect-dependencies workflow concurrency and
  semantic version bumps do not apply. Prowl keeps local, notarized, date-based releases.

---

## 2026-04-20 — Review through v0.8.1

### Upstream changes reviewed

Reviewed 47 commits on `supabitapp/supacode` from `0150ceaf` (v0.8.0) through `c4e9be3b` (v0.8.1, 2026-04-19). Significant additions:

- **Tuist migration** (`02d75cd5` + ~20 follow-ups) — upstream replaced the checked-in Xcode project with a generated Tuist workspace. Driven by a `release-tip` archive regression (the new `supacode-cli` Xcode target archived with `SKIP_INSTALL = NO`, polluting archives with `Products/usr/local/bin/supacode` and breaking `developer-id` export) plus configuration sprawl across pbxproj, Makefile, CI workflows, and in-source `sed` patching of Sentry/PostHog keys in `supacodeApp.swift`.
- **CLI tool** (`e57d744d`, #227) — Unix-socket CLI `supacode` with `open`/`worktree`/`tab`/`surface`/`repo`/`settings`/`socket` subcommands. Orchestration-focused, dispatches via deeplink URLs.
- **Script CLI + deeplinks** (`788dcff4` #253, `1f38a0c1` #246) — multi-script per repo, `worktree run --script UUID`, `worktree script list`.
- **Folder (non-git) repo support** (`68e44966`, #257); atomic `sidebar.json` state (`7981cf34`, #254); Icon Composer app icon for macOS 26 Liquid Glass (`f37b698f`, #230).
- **Ghostty `toggle-background-opacity`** (`1792e377`, #225) — same feature fork already implements via `5ca2bf4e` (2026-03-21, 3 weeks earlier).
- Misc Ghostty fixes and editor integrations (RubyMine #248, surface width #233, local URL paths #236, split-preserve-zoom #241, openFinder→openWorktree rename #247).

### Decisions

- **Tuist migration**: **Skip.** Fork sidesteps the `release-tip` archive bug by construction — `ProwlCLI` is a SwiftPM `executableTarget`, not an Xcode target, and is pre-copied into `Resources/prowl-cli/` as a folder reference. Archives already contain only `Products/Applications/supacode.app`; `/usr/local/bin/prowl` symlinks into `/Applications/Prowl.app/Contents/Resources/prowl-cli/prowl`. Migrating would force rewriting the `/release` skill, notarization flow, appcast generation, and every rebrand patch for zero functional gain.
- **CLI (#227, #253, #246)**: **Skip.** Fork's `prowl` CLI targets agent scripting (`send`/`key`/`read` with stdin piping, output capture, timeout, keyboard token synthesis); upstream's CLI targets orchestration (`worktree archive/pin/delete`, `tab/surface new/split/close`, `repo`/`settings`/`socket`). The two are orthogonal, not duplicative. Future work may selectively port upstream's orchestration commands into `ProwlCLI`'s envelope-based transport, but nothing forces action today.
- **Ghostty `#225`**: **Defer to next sync of the affected files.** Upstream version is slightly cleaner — state on `GhosttyRuntime` instead of per-view (fixes multi-split-same-window ambiguity), reset on config reload, early-return in fullscreen, Bool return, debug logs. No user-visible bug in fork. When next editing `GhosttySurfaceView.swift` / `GhosttySurfaceBridge.swift` / `GhosttyRuntime.swift`, replace fork's implementation with upstream's and preserve the fork-only `chromeBackgroundColor(...)` call in `applyWindowBackgroundAppearance`. *(Status 2026-07-12: never executed — those files were edited multiple times since, and the toggle state is still per-view (`isBackgroundOpaqueOverride` in `GhosttySurfaceView.swift`).)*
- **Everything else**: Nothing user-facing for the fork. Re-evaluate on next review.

---

## 2026-04-08 — Full upstream review & change-list format migration

### Upstream changes reviewed

Reviewed all upstream (`supabitapp/supacode`) commits from our last sync through `0150ceaf` (v0.8.0). Key additions:

- **Deeplinks** (`a7f6d81f`) — new deeplink handling
- **Coding agent hook system** (`61356be1`) — hooks for Claude Code and Codex
- **Auto-hide tab bar for tmux** (`dc8eb02e`) — new setting
- **Inhibit command on script & single-tab bar hiding** (`301cf398`)
- **Auto-delete archived worktrees** (`666d440d`) — configurable retention period
- **Terminal layout persistence and restoration** (`771e4aab`)
- **Global worktree settings** (`c29ee5a5`) — global defaults with per-repo overrides
- **Merged worktree action picker** (`4db25220`) — replaces auto-archive toggle
- **Global defaults for copy flags and merge strategy** (`ce214902`) — overlaps with our #178

### Decisions

- **#178 (global defaults)**: Upstream added `ce214902` which covers global defaults for copy flags and merge strategy. Our fork branch `feat/issue-178-global-defaults` (`c7a10bd0`) implements the same concept. On next upstream sync, check for conflicts and prefer upstream's implementation where equivalent; keep fork extensions if any.
- **#173, #177**: Both PRs already merged.
- **change-list.md format**: This file is no longer maintained as a per-commit tracking table. It is now a dated log of upstream reviews and fork decisions. Use the `/check-upstream-changes` command to generate diffs against the baseline.

---

## Old Log

The table below was the original per-commit tracking format, preserved for reference.

| summary | commit hash | status |
| --- | --- | --- |
| Fix initial prompt path by normalizing trailing slash so working directory is set correctly on launch. | `fbfeec4` | Merged upstream |
| Align embedded Ghostty accessibility with Ghostty.app so AX-driven dictation/transcription tools like Typeless can recognize terminal panes correctly. | `aa57f08` | Merged upstream |
| Add fork sync and personal release workflow docs plus helper scripts (`sync-upstream-main.sh`, `release-to-fork.sh`). | `3599f5f` | Fork only |
| Remove `Cmd+Delete` shortcut from worktree archive actions, so the key can be handled by Ghostty/terminal behavior. | `022bb87` | Fork only |
| Harden fork release script: detect target repo from `origin` and add fallback (`gh api` + upload) when `gh release create` fails. | `058177e` | Fork only |
| Add local app notarization flow to fork release script (Developer ID signing + `notarytool` + stapling) for personal releases. | `a66c4b2` | Fork only |
| Clarify fork customization guidance and release workflow docs for this fork. | `b7f4e0b` | Fork only |
| Ignore local build artifacts in fork working tree to reduce noise. | `cccd36d` | Fork only |
| Harden upstream sync script/docs with deterministic fetch/merge flow and safer failure handling. | `56deb49` | Fork only |
| Add repo-scoped custom command buttons with configurable icon/title/command/execution mode and shortcut overrides. | `76046bc` | Fork only |
| Refine custom shortcut editor layout by tightening modifier symbol and toggle spacing. | `b5c58e4` | Fork only |
| Execute Terminal Input custom commands by injecting return key so the command runs immediately. | `562042f` | Fork only |
| Disable push-triggered `tip` release workflow in fork to avoid expected CI failures. | `85b3fd7` | Fork only |
| Enforce notarized-only fork releases; block non-notarized publishing path in release script and docs. | `2ab70fd` | Fork only |
| Move repo-scoped settings files to `~/.prowl/repo/<repo-last-path>/` (was `~/.supacode/repo/…`) with legacy migration from repo root files. | `ea9259f` | Fork only |
| Add `/fork-release` slash command for upstream sync and private release workflow. | `64829dc` | Fork only |
| Add diff window with file tree sidebar and YiTong DiffView for viewing worktree changes. | `0d03848`, `09194c4` | Fork only |
| Wire up diff badge click in worktree row, `Cmd+]` shortcut, and Show Diff menu item. | `59dc4f6` | Fork only |
| Preload all file contents on diff window open for instant file switching. | `5850576` | Fork only |
| Add toolbar with sidebar toggle, diff style picker (split/unified), `Cmd+W` close, and window frame persistence. | `8985fc2` | Fork only |
| Add Canvas (Live Sessions) feature: free-form view displaying all open tabs as draggable, resizable cards in a balanced grid layout with pinch-to-zoom (cursor-anchored), two-finger scroll panning, organize button, and fit-to-view on open. | `2c1d9aa`…`80df1b1` | Fork only |
| Render full split pane layout in Canvas cards with `pinnedSize` propagation through the split tree to prevent terminal reflow during zoom. Enable resize handles on all four edges and corners. | `12496d5` | Fork only |
| Show all open tabs (not just active) as separate cards in Canvas; per-tab layout, focus, resize, and occlusion management. | `e5992ea` | Fork only |
| Fix Canvas grid layout: batch positioning to avoid overlap, stale layout cleanup, and organize/fit-to-view helpers. | `80df1b1`, `2653c06` | Fork only |
| Add two-finger scroll to pan canvas via NSView scroll-wheel interception. | `2738c24` | Fork only |
| Fix canvas pinch-to-zoom to anchor on cursor position instead of origin. | `c24e092` | Fork only |
| Add PreToolUse hook to block `gh pr create` targeting upstream; PRs must explicitly target fork. | `9970560` | Fork only |
| Add PR target rule to CLAUDE.md: always target `onevcat/supacode`, never upstream. | `962ba62` | Fork only |
| Rebrand user-facing identity from Supacode to Prowl: app name, icon, bundle display name, settings file paths (`prowl.json`), subsystem identifiers, and about/UI strings. Keep module name as `supacode` for code compatibility. | `5f7d84a`…`5676418` | Fork only |
| Add public release infrastructure: Sparkle EdDSA key setup, date-based version scheme (`YYYY.M.DD`), full release script with DMG/notarization/appcast, `install-release` Makefile target, `/release` and `/sync-upstream` commands. | — | Fork only |
| Parallelize repository startup loading to speed up launch with many repos. | `8dd8eac` | Merged upstream |
| Run bundled `wt` binary directly instead of shell discovery for faster worktree operations. | `ed27b31` | Merged upstream |
| Evolve Canvas card layout algorithm (waterfall → MaxRects → combined row-break + waterfall packing) for better space utilization; auto-arrange cards on first Canvas entry per session; improved fit-to-view scaling. | `15bafd1`…`fc81375` | Fork only |
| Add Canvas toggle shortcut; auto-focus the previously active card when entering Canvas; exit Canvas to the focused worktree+tab; move Canvas and Show Diff to View menu. | `38a6361`, `3c4dc3c`, `17df275`, `d9dde25` | Fork only |
| Implement Ghostty `prompt-title` and `open-config` callbacks: surface prompts update tab titles; open-config opens Ghostty config in default text editor. | `2b55336`…`1352165` | Fork only |
| Route Ghostty window actions (`toggle_fullscreen`, `toggle_maximize`, `toggle_background_opacity`, `quit`, `close_window`) through Prowl; quit goes through TCA `requestQuit` for confirm-before-quit. | `5ca2bf4`…`4732780` | Fork only |
| Filter duplicate and unsupported Ghostty actions from command palette. | `512c5b3`, `c8c562f` | Fork only |
| Add command finished notification for long-running terminal commands with configurable duration threshold; Canvas highlights the entire title bar for unseen notifications, tracked per-tab. | `182e165`…`d7bb4b6` | Fork only |
| Mark notifications as read on key input to focused terminal surface; suppress command finished notification after recent user interaction. | `26968c1`, `2db9ae5` | Fork only |
| Add repository snapshot startup cache to skip full git scan on re-launch when worktrees haven't changed. | `7136591` | Fork only (upstream #162 closed unmerged) |
| Fix unicode paths in diff and untracked file output. | `1b32a26` | Fork only |
| Fix settings migration to copy instead of move, preserving `~/.supacode` for upstream compatibility. | `07121b6` | Fork only |
| Use Claude to generate user-facing release notes; skip generation when pre-written notes exist. | `64d0928`, `849b5cf` | Fork only |
| Remove CI release workflows (`release.yml`, `release-tip.yml`) and make tip update channel equivalent to stable; releases are now handled locally via `/release` skill. | `7f79078`, `4546b66` | Fork only |
