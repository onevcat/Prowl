# Codex JSONL lifecycle spike

Date: 2026-09-12. Base: `4a47564bdc622b53af9a3c91060e4928c2340ef8`.

## Decision

**Go for a guarded lifecycle supplement; no-go for replacing screen detection.**

Codex 0.154.0 writes explicit start, completion, and cancellation records promptly in
ordinary interactive TUI sessions, without hooks. File notification latency is not
the main obstacle in these samples. Foreground session identity after `/new`,
approval/input waits, and process death remain separate problems.

Do not connect this directly to Working/Idle yet. No application behavior changes
are included in this spike.

## Environment and method

- macOS 26.6.2, arm64; Python 3.14.7; `codex-cli 0.154.0`.
- Three controlled PTY process runs, four session IDs, 13 model turns. The first
  two TUI processes ran concurrently in the same directory and configuration home.
- An isolated temporary `CODEX_HOME` used the existing login through an auth-file
  symlink. Minimal configuration retained the user's model, disabled hooks, set
  `notify = []`, and trusted only the temporary work directory. Launch arguments
  also specified `--disable hooks -c notify=[] -s read-only -a on-request`.
- The runtime selected `gpt-6-astra`; `/plan` selected medium effort itself. No
  profile launcher, managed hooks, MCP setup, or existing user pane was involved.
- `probe.py` recorded PTY input/output times, incremental JSONL visibility, and
  the TUI PID's open rollout descriptors. JSONL polling used a nominal 20 ms loop,
  discovery a 100 ms interval, and `lsof` a 1 s interval. Scheduling and synchronous
  descriptor inspection can increase these intervals.
- A separate `watch_file.py` run used macOS `kqueue` vnode notifications on an
  already-bound file for two further turns within the 13-turn total.
- `evidence.json` retains controls, file ownership transitions, lifecycle records,
  event counts, exits, and vnode observations. Session history loaded before a
  process started and files never owned by that process are excluded from latency
  aggregation. The directory-wide probe reader is **not** a production binding rule.

## Results

| Case | Observed result | Consequence |
| --- | --- | --- |
| First prompt | No rollout descriptor before submission. `task_started` became readable 76.3 ms after Enter. | Startup needs an unresolved state and discovery retry. |
| Same-session repeats | Distinct `turn_id` values, paired starts and completions. | State must be keyed by session and turn. |
| Two TUIs, same cwd/home | Each initially held its own distinct writable rollout descriptor. | Descriptor ownership distinguishes these sessions; cwd cannot. |
| Escape during `sleep 30` | A matching `turn_aborted` was recorded. | Cancellation has a usable explicit boundary in this case. |
| Approval request | The TUI displayed the approval menu for `/usr/bin/true`. No standalone waiting event appeared; the log was unchanged for 36.8 s before Escape. Escape produced `turn_aborted`. | An open turn does not prove Working. The command was not approved. |
| Plan-mode input question | The TUI displayed Red/Blue choices. No standalone waiting event appeared; the log was unchanged for 35.3 s before Escape. Escape produced `turn_aborted`. | Input waits still need screen evidence or another explicit channel. |
| `/new` | Old and new rollouts remained open for writing in the **same** PID. | Ownership alone no longer identifies the foreground session. |
| `/new`, without prior shell execution | The second TUI reproduced the two-writable-file state for at least 128 s, until normal exit. | This is not just the retained background terminal from the first run. |
| Forced process exit during work | SIGKILL status 9; no completion or abort for that turn during the post-exit observation or later resume. | Process lifetime must invalidate the open turn. |
| Explicit resume after that exit | A new PID held the original rollout. The TUI rendered an interruption notice; a new prompt produced a new paired turn. The old unmatched start remained in history. | Replaying all historical starts cannot establish current activity. |
| Normal idle exit | Both remaining TUI processes exited with status 0 via Ctrl-D. | Probes were closed without touching user sessions. |

During waits, a tool invocation was persisted (`custom_tool_call` for the approval
probe, `function_call` for the question). This is not a general waiting-state event:
the call alone does not prove whether execution is running, paused, denied, or
already resolved but not yet flushed. The screen was inspected through captured
PTY output, not through a native Prowl GUI interaction pass.

### Timing

The polling observer saw these record timestamp-to-read delays:

| Event | Samples | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: | ---: |
| `task_started` | 13 | 9.5 ms | 20.3 ms | 81.1 ms |
| `task_complete` | 9 | 3.9 ms | 19.5 ms | 24.8 ms |
| `turn_aborted` | 3 | 12.5 ms | 19.6 ms | 21.1 ms |

Enter-to-visible-start ranged from 21.3 to 96.9 ms across the 13 turns. These
measurements include observer overhead; they are not Prowl end-to-end latency.

For the two vnode-notification turns, start record observation delays were 0.815
and 0.231 ms; completion delays were 0.503 and 0.673 ms. Both produced real vnode
notifications and readable appended records. Timestamps have millisecond precision,
so these sub-millisecond values are indicative, not a precise storage benchmark.
The vnode observer timestamp is sampled just before reading the notified file.
This tests visibility to another process, **not fsync or power-loss durability**.

## Existing Prowl integration points

- `ProcessDetection.openFilePaths` already filters for writable descriptors using
  `proc_pidinfo` / `proc_pidfdinfo`. The spike used `lsof` to independently inspect
  that same OS property; it did not execute the Swift resolver in the GUI.
- `AgentSessionResolver.resolveUncached` assigns exact confidence when writable
  descriptors yield one unique session. Two sessions cannot take that branch.
  The resolver can then fall back to other evidence; this spike did not establish
  which fallback wins in a live Prowl pane after `/new`.
- Resolved session results can be cached for 5 seconds. A lifecycle consumer must
  not mistake cached identity for freshly verified foreground identity.
- `AgentTranscriptResultReader` already parses `task_complete` and `turn_aborted`
  for result extraction. That reader is not a live state machine, and must not be
  treated as one: an older completed result can precede a new active turn.

## Proposed boundary for a follow-up implementation

1. Bind to a verified process identity `(pid, start time)` and a freshly established
   foreground session. A unique writable descriptor is useful evidence; multiple
   writable rollouts require additional foreground evidence. Never choose by mtime.
2. Register a watcher before taking the initial read snapshot, then drain appended
   complete lines with an offset and pending partial-line buffer. Handle truncation,
   replacement, and duplicate wakes. Establish a history baseline without promoting
   an old unmatched start into a fresh runtime event.
3. Scope events to `(process epoch, session ID, turn ID)`. A matching completion or
   abort closes that turn only. A stale completion must not end a newer turn.
4. Treat an open turn as **in progress, possibly waiting**. Current confirmation or
   input UI must take precedence over an inferred Working state.
5. On process death or unresolved session transition, invalidate runtime evidence
   and use the existing fallback. Do not manufacture successful completion.

The first implementation gate is reliable foreground identity across `/new` and
resume, not faster JSONL I/O. The measured event path is promising once that gate
is satisfied. The documented app-server status channel is another research option,
but attaching it to these existing TUI processes was not tested here:
[official app-server status documentation](https://learn.chatgpt.com/docs/app-server#track-thread-status-changes).

## Reproduce

Create a private temporary root containing `home/` and `work/`. Put a minimal
`config.toml` in `home/`, explicitly disabling hooks and notifications, and supply
login access without committing credentials. The probe consumes model usage.

```sh
python3 spikes/codex-log-events/probe.py "$probe_root" first
```

In another terminal, append control records to `$probe_root/first/control.jsonl`.
Send text and Enter separately to avoid the TUI's paste timing heuristic:

```json
{"action":"send","text":"Reply with exactly PROBE_OK. Do not use tools."}
{"action":"send","text":"\r"}
```

Supported controls are `send`, `kill` (only the child TUI PID), and `stop`.
`mark` records an observation without sending input. The probe has a 15-minute
limit. `--resume SESSION_ID` starts an explicit resume run. Raw captures remain
under the temporary root; only the content-free export belongs in the repository.

```sh
python3 spikes/codex-log-events/watch_file.py "$rollout_path" > "$probe_root/vnode.jsonl"
python3 spikes/codex-log-events/summarize.py "$probe_root" > evidence.json
```

The summary expects runs named `first`, `second`, and `resumed`, matching this
experiment. It is an evidence exporter, not a reusable product API.

## Validation and limits

The scripts were exercised against the real TUI and real files; all 13 starts,
9 completions, 3 cancellations, and the unmatched crash turn are retained in the
evidence. The temporary auth symlink was removed after all probes exited.
Evidence consistency assertions passed, and all three Python scripts parsed.
`make check` passed, including 153 script tests; `make build-app` passed with
zero warnings and errors.

No native GUI acceptance, production watcher, network-failure injection, shared
daemon/remote TUI mode, file replacement/truncation injection, or supported-version
matrix was tested. The JSONL format is treated as version-specific behavior, not
a stable public contract. The sample is small and does not establish worst-case
latency under system load.
