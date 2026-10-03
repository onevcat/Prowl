# Observability Runbook

> Living document of entry 020. Migrated from `doc-onevcat/observability.md` on 2026-07-12; update in place.
> Known drift (2026-07-12): the App-Hang tracking sections below describe machinery removed in #236/#241 (SentryEventFilter is deleted); pending an update pass — see 001-action.md.

Quick-start reference for investigating production issues using the Sentry + PostHog pipelines built into Prowl. When you (or an agent) come back to diagnose something, read this first — it's the map.

## TL;DR

- **Crashes / errors / App Hangs** → Sentry (`sentry issue view <id>` or https://onevs-den.sentry.io/)
- **User behavior / product questions / memory trends** → PostHog (dashboard)
- **Long-running memory growth** → PostHog events `app_memory_baseline` and `memory_threshold_<N>mb` (see [Memory explosion playbook](#memory-explosion))
- **Credentials + scopes** → `~/.sentryclirc` (`event:read`, `project:read`, `project:releases`)
- **Debug builds send nothing** — `#if !DEBUG` gates every SDK call

## Stack overview

Two independent pipelines, both initialized in `App/Sources/App/ProwlApp.swift > bootstrapTelemetry`:

### Sentry (crash + error + App Hang)

- `options.releaseName = "prowl@<VERSION>"` — matches the release name that `release.sh` registers via `sentry-cli releases new`
- `options.environment = "tip"` for tip-channel users, `"production"` otherwise
- `options.tracesSampleRate = 0.05` — 5% of transactions get performance traces
- `options.enableAppHangTracking = true` + `appHangTimeoutInterval = 3` — main-thread stalls ≥ 3s get reported
- `options.beforeSend = SentryEventFilter.filterSystemHang` — client-side filter for known system-induced hangs
- Watchdog Termination **not** enabled (unsupported on native macOS)

### PostHog (product analytics)

- 16 hand-instrumented events — no autocapture
- `enableSwizzling = false`, `captureApplicationLifecycleEvents = false`, `captureScreenViews = false` — all off, avoids `Application Opened` / `$screen` noise
- Super properties registered once at startup via `AnalyticsContext.superProperties`

### User identification

`InstallIdentifier.current` — a random UUID generated on first launch, persisted in `UserDefaults`, cleared when analytics is toggled off. Same ID used for both SDKs so cross-referencing works.

### Credentials flow

`Config/Secrets.env` (gitignored) → Makefile passes to `xcodebuild` as build settings → substituted into `Info.plist` `$(VAR)` placeholders → read at startup via `Bundle.main.infoDictionary`. Template at `Config/Secrets.env.template`.

## CLI tools

Two separate binaries, same `~/.sentryclirc`:

| Binary | Homebrew | Purpose |
|---|---|---|
| `sentry` (new) | `getsentry/tools/sentry` | Day-to-day inspection: `sentry issue view <id>`, `sentry issue list`, `sentry issue events <id>` |
| `sentry-cli` (classic) | `getsentry/tools/sentry-cli` | dSYM uploads + release registration, invoked by `release.sh`. No useful `issue view` subcommand. |

PostHog: dashboard only, no CLI needed.

### Auth setup

```ini
# ~/.sentryclirc
[auth]
token=sntryu_xxxxxxxx

[defaults]
url=https://sentry.io/
org=onevs-den
project=prowl-macos
```

Token scopes: `event:read`, `project:read`, `project:releases`. Generate at <https://sentry.io/settings/account/api/auth-tokens/>.

## Diagnostic playbooks

### Memory explosion

*"User says Prowl was at 500 MB, now it's at 15 GB after running overnight."*

1. **Sentry**: `sentry issue list --query "memory_threshold"` → look for `memory_threshold_4096mb` or `_8192mb` events. `sentry issue view <id>` gives you breadcrumbs (last 50 TCA actions) and device/OS context. The breadcrumb trail right before the spike often hints at what the user was doing.
2. **PostHog**: filter on `memory_threshold_2048mb` events (the earliest signal). Critical queries:
   - **Correlation with `terminal_tab_count`** — if tab count scales with resident_mb, the leak is surface/ghostty driven
   - **Correlation with `repository_count`** — if repo count scales, repo state / GitHub integration driven
   - **Counters flat but memory grows** — leak is inside a fixed-count structure (scrollback, caches, Observable state). This is the hard case: Sentry Profiling can't see it (doesn't run between transactions), you'll need to reproduce locally with Instruments.
3. **PostHog**: `app_memory_baseline` histogram — the distribution of normal-use working sets. If median is already 1.5 GB, the leak starts earlier than the 2 GB threshold catches.
4. **Individual user suspect**: if you have an `install_id` (from Sentry `user.id` tag or PostHog person), go to PostHog Persons → find them → their event timeline shows exactly what they did from launch to explosion.

### Suspicious Sentry issue — is it real?

*"New issue showed up, but I have no idea if it's our bug or macOS noise."*

1. `sentry issue view <id>`
2. **Check stack trace**: any `[app]` frames? If yes → real app issue, dig in.
3. **All frames are system (AppKit/CGS/mach_msg)?** Compare against `SentryEventFilter.systemHangSignatures` — if none of those substrings appear, it's a novel system pattern. Decide: ignore, or add to the filter.
4. **To add a new filter pattern**: append to `SentryEventFilter.systemHangSignatures` array. No test changes needed for a simple addition.

### DAU / engagement check

*"Did the tip channel release tank activation?"*

1. PostHog Insights → filter by `environment = "tip"` (Sentry equivalent) or by super property `app_version = "prowl@X.Y.Z"`
2. DAU proxy: count unique `distinctId` with ≥ 1 event
3. Session lengths: `app_quit.session_duration_seconds` distribution (dropped events that leak past quit are rare on macOS since we capture at confirm-quit, but keep in mind)
4. Cold-start count: `app_launched` (since PR #208, fires once per cold launch only — not on window focus changes)

## Event catalog

### Super properties (every event carries these)

Set once via `AnalyticsContext.superProperties` at `PostHogSDK.shared.register(...)`.

| Key | Example | Source |
|---|---|---|
| `app_version` | `2026.4.17` | `CFBundleShortVersionString` |
| `build_number` | `20260417` | `CFBundleVersion` |
| `os_version` | `26.3.1` | `ProcessInfo.operatingSystemVersion` |
| `os_major` / `os_minor` | `26` / `3` | split of above for easy aggregation |
| `device_model` | `Mac14,9` | `sysctlbyname("hw.model")` |
| `cpu_arch` | `arm64` / `x86_64` | `#if arch(...)` |
| `locale` | `en_JP` | `Locale.current.identifier` |

### Events

Everything is hand-instrumented via `analyticsClient.capture(...)`. Events marked with ✱ carry additional properties beyond the super properties.

| Event | Extra properties | Fires when |
|---|---|---|
| `app_launched` ✱ | — | cold launch (`.appLaunched` action) |
| `app_quit` ✱ | `session_duration_seconds` | user confirms quit |
| `worktree_opened` ✱ | `action` (editor/finder/terminal/IDE) | open worktree flow |
| `repository_added` ✱ | `count` | N repos added at once |
| `app_memory_baseline` ✱ | `resident_mb`, `uptime_seconds`, counters† | once, at 3 min uptime |
| `memory_threshold_2048mb` ✱ | `resident_mb`, `baseline_mb`, `growth_ratio`, counters† | first crossing of 2 GB |
| `memory_threshold_4096mb` ✱ | same + also Sentry `capture(message:)` | first crossing of 4 GB |
| `memory_threshold_8192mb` ✱ | same + Sentry capture | first crossing of 8 GB |
| `terminal_tab_created` | — | new tab in worktree |
| `terminal_tab_closed` | — | tab closed |
| `script_run` | — | user-triggered script |
| `worktree_created` / `_deleted` | — | lifecycle |
| `worktree_pinned` / `_unpinned` | — | ordering |
| `branch_renamed` | — | |
| `github_pr_opened` / `github_ci_check_opened` | — | click-through to GitHub |
| `settings_changed` | — | only if analytics still enabled after change |
| `update_checked` | — | manual Check for Updates |
| `repository_removed` | — | |

† `counters` = `{ repository_count, opened_worktree_count, terminal_tab_count }` assembled by the `contextProvider` closure in `ProwlApp.swift` from the TCA store + `WorktreeTerminalManager`.

Thresholds are **monotonic per session**: crossing 2 GB → dropping to 1 GB → crossing 2 GB again fires `memory_threshold_2048mb` exactly once. We want the session's envelope, not event storms.

## Known noise and filters

### System-induced App Hangs

Wake-from-sleep, Mission Control space switch, external display (dis)connect all trigger `_NSMenuBarDisplayManagerActiveSpaceChanged` → NSWindow replicant rebuild → `mach_msg` IPC to WindowServer. On a busy main thread this can block > 3s. **Not an app bug.**

Filtered in `App/Sources/Support/SentryEventFilter.swift`. Current signatures:

- `_NSMenuBarDisplayManagerActiveSpaceChanged`
- `NSMenuBarLocalDisplayWindow`
- `NSMenuBarPresentationInstance`
- `NSMenuBarReplicantWindow`

Filter is conservative: drops only when **(a)** `mechanism.type == "AppHang"` **and** **(b)** zero in-app frames **and** **(c)** at least one frame matches. Any novel pattern still gets through.

### PostHog autocapture

Disabled via `captureApplicationLifecycleEvents = false` + `captureScreenViews = false` + `enableSwizzling = false`. Rationale: `Application Opened` / `Backgrounded` fire on every Cmd+Tab and would burn the 1M/mo free tier at ~100 DAU.

### Things that look like bugs but aren't

- `sentry org list` returns 403 — missing `org:read` scope. Not needed for our flows (org is in `~/.sentryclirc`). Ignore.
- `sentry auth status` says "Could not verify credentials" but `sentry issue view` works fine — same 403 reason. Token is actually valid.
- `Library: posthog-ios` shown in PostHog for macOS events — the Swift SDK ships as `posthog-ios` for both platforms. Use `device_model` + `cpu_arch` super properties to discriminate.

## File map

| Concern | File |
|---|---|
| SDK init + `beforeSend` wiring | `App/Sources/App/ProwlApp.swift > bootstrapTelemetry` |
| PostHog event wrapper | `App/Sources/Clients/Analytics/AnalyticsClient.swift` |
| Super properties | `App/Sources/Support/AnalyticsContext.swift` |
| User identity | `App/Sources/Support/InstallIdentifier.swift` |
| Memory probe (`phys_footprint`) | `App/Sources/Support/MemoryProbe.swift` |
| Memory watchdog (baseline + thresholds) | `App/Sources/Support/MemoryWatchdog.swift` |
| System hang filter | `App/Sources/Support/SentryEventFilter.swift` |
| Release pipeline (dSYM upload + release tracking) | `scripts/release.sh` |
| Credentials template | `Config/Secrets.env.template` |

## Quick reference: making changes

- **Add a new PostHog event**: call `analyticsClient.capture("event_name", ["key": value])` in the relevant reducer. Test coverage mandatory per CLAUDE.md.
- **Add a new super property**: one-line addition to `AnalyticsContext.superProperties`. Applies to every event automatically.
- **Raise / lower a memory threshold**: edit `thresholdsMB` default in `MemoryWatchdog.init`. Update `MemoryWatchdogTests` assertions to match.
- **Filter a new Sentry noise pattern**: append to `SentryEventFilter.systemHangSignatures`. One line.
- **Sentry environment**: `bootstrapTelemetry` always configures `"production"`; the retired update channel no longer affects telemetry.
- **Reset analytics locally**: toggle off in Settings → toggle on. `AnalyticsClient.reset` clears both the PostHog identity and the install UUID.

## Open gaps (possible future work)

- `terminal_tab_closed.tab_lifetime_seconds` — needs `TerminalClient.Event` extension (`.tabClosed(lifetime)`) and moving capture from action-trigger to event-receipt.
- `script_run.exit_code` / `duration_ms` — ghostty doesn't expose shell exit status via its public API. Skipped.
- Ghostty surface byte counter (scrollback size) — currently `private var surfaces` on `WorktreeTerminalState`. If the memory-growth signal points to scrollback, this is the next handle to expose.
- Sentry Profiling — intentionally off (`profilesSampleRate` unset). Profiling only samples during transactions, which for a long-lived desktop app means 8-hour memory drift is invisible to it. Revisit if we have a concrete transaction-level question.
- User feedback inline — GitHub Issues for now; if volume grows, consider Sentry User Feedback API.

## Related PRs

- [#207](https://github.com/onevcat/Prowl/pull/207) Credentials pipeline (`Secrets.env` → `Info.plist` → `Bundle`)
- [#208](https://github.com/onevcat/Prowl/pull/208) Event quality — super properties, Sentry environment, `session_duration_seconds`, autocapture off, `app_launched` (renamed from `app_activated`) moved to cold start
- [#210](https://github.com/onevcat/Prowl/pull/210) dSYM upload + Sentry release tracking in `release.sh`
- [#211](https://github.com/onevcat/Prowl/pull/211) System hang filter + 3s `appHangTimeoutInterval`
- [#212](https://github.com/onevcat/Prowl/pull/212) Memory watchdog (baseline + threshold crossings + Sentry escalation at 4GB)
