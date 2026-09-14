# 068.002 — Native runtime state implementation

Status: implemented; acceptance complete with the fullscreen case excluded by onevcat. Authorized on 2026-09-15 after #806 merged.

## Sequence and acceptance

| Stage | Required evidence | Status |
| --- | --- | --- |
| A | Native generation/config-root contract; assigned children; failure and session boundaries | Verified with the limits below |
| B/C | Bounded acquisition and decoding, red/green parser/provider tests | Complete |
| D | Shared arbitration, ordering, ownership, and readiness regressions | Complete |
| E | Debug pane E2E matrix and final regression checks | Native terminal/CLI and standard wheel cases verified; fullscreen case excluded |

Acceptance records distinguish intermediate states from final Idle. Runtime traces
stay in the ignored capture directory; the contract and scoped results are below.

## Contract refinement

Interactive 2.1.270 registry state already aggregates real assigned children and
background shell work. Captures observed `busy` after parent `turn_duration` with
`pendingBackgroundAgentCount: 1`, retained `busy` across `/new`, and `shell` while
background Bash still ran. Reused children and TaskStop cancellation also returned
the aggregate to Idle. `/compact` and a local HTTP 400 response produced Busy/Idle.

The implementation therefore consumes native aggregate snapshots directly. JSONL
remains corroborating experimental evidence, not a second production work ledger.
This replaces proposed slice C's duplicate reconstruction: log-only child ends can
precede nested work, and shared-session writes have no per-PID ownership. Native
snapshots preserve that ownership and recover on late attach without replaying
history. No native Idle is converted to a log turn end or trusted receipt.

The registry's `procStart` matched `TZ=UTC ps -o lstart` at whole-second precision;
`startedAt` did not. Prowl compares the former to OS generation and checks exact OS
generation before and after reading. Root relocation was observed with a disposable
`CLAUDE_CONFIG_DIR`; Prowl supplies that root through its existing launch profile.
Manual shell-only relocation and daemon/remote session kinds retain screen fallback.

## Native Debug acceptance

Claude Code 2.1.270 ran without hooks in disposable panes on a separate Debug socket.
The capture harness retained 1,384 native CLI observations, including 290 where the
screen was Idle while the final decision was `native.working`. Twenty-five trace
assertions passed. This is sampled evidence, not proof of all possible interleavings.

| Case | Observed result |
| --- | --- |
| Fresh attach before transcript persistence | `native.idle`, even when public transcript identity was unresolved |
| Normal long output | Working through raw Idle samples, then native Idle |
| AskUserQuestion | Native Blocked; blocked wait resolved; answer resumed and completed |
| Forced Bash permission | Native Blocked; approval resumed execution; rejection completed separately |
| Pre-output cancellation | Native Working then Idle before the local delayed response arrived |
| Streaming cancellation | Output was present; Escape returned native Idle |
| Detailed transcript viewer | Viewer stayed open through Working and completion; Idle wait resolved with heuristic confidence |
| Same-session processes | Busy pane stayed Working; quiet peer stayed Idle |
| New / quiet resume / restart | Current PID/session state recovered without replaying historical work |
| Assigned background child | Parent answer was complete, aggregate stayed Working; Idle wait timed out |
| Background shell | Screen showed completed parent and Idle composer; native `shell` retained Working and blocked Idle wait until shell completion |
| Missing / partial registry | Screen fallback retained completed frame; restoring the file restored native evidence without input |
| Unsupported native state | Authority revoked; valid file restored native state |
| First attach with existing blocker | Final-build fault injection supplied Idle after revocation while a question remained visible; the screen blocker stayed Blocked, then native Waiting recovered |
| API HTTP 400 | Local endpoint returned an actual API error; Working then Idle, with no successful-task receipt |
| Existing Codex provider | Hook-free native turn retained `log.openWork` then `log.turnEnded` |

The interactive PTY contract extension separately covered `/new` with active child
work, child reuse, TaskStop, `/compact`, fork/resume, and a relocated config root.
A requested foreground child was backgrounded by this runtime; that request does
not prove synchronous foreground-child execution. Unsupported daemon/remote kinds
and shell-only custom roots retain screen fallback. Older runtime versions were not
installed or tested.

### Initial desktop gate

Computer Use failed with `cgWindowNotFound`, then its native connection closed.
A physical mouse-wheel scroll and a desktop screenshot could not be verified. CLI
PageUp did not establish the scroll overlay and is not counted as passing that case.
The detailed transcript viewer is separately verified, not a substitute claim.

To close this gate on an accessible desktop: run a long response, scroll up until
the overlay appears, and capture `agents read` plus `read --source detection` while
Working and after completion without returning to the bottom. Repeat with an input
blocker, then return to the bottom and confirm state continuity. Record that receipt
here before marking the chapter complete.

## Deterministic checks

Red runs established missing provider facts, the suspended-completion regression,
native Idle readiness on an unmatched screen, and first attachment preserving an
existing blocker. A Busy transition also preserves a newly changed blocker; it only acknowledges
a blocker retained from the preceding observation. Tests cover schema/size bounds,
process generation before/after reads, old atomic replacement, recovery without
log writes, same-session independence, capture ordering, completion fences, and
readiness vetoes. Codex decoder/provider and shared policy suites remain covered.

Local captures and replay assertions are in
`.local/agent-screen-captures/claude-provider-20260915/`; raw runtime/session data is
not published. `native-verification.json` records the 25 evidence checks and the
explicit desktop limitation. Final verification: 92 selected app tests passed with zero errors;
`make check` passed, including 158 script tests; standard `make build-app` passed
with zero errors or warnings. CLI build, smoke, unit (219 XCTest plus 78 Swift
Testing), and integration (105 tests) passed. The final test rebuild emitted five
third-party Dependencies scan warnings; the standard app build had none.

All owned Debug instances, disposable runtime processes, and local HTTP error
servers were stopped. No test runtime PID registry files remained after cleanup.
The API test pane's close prompt could not be answered through the unavailable
desktop channel, so its owned Debug instance was terminated during cleanup.

The final blocker refinement received a fresh Debug question/answer regression.
Its first harness attempt opened a pane before workspace restore completed; that
pane disappeared. Retrying after restore completed passed. This was not counted
as a passing first attempt or a detector failure.


### Desktop retry on 2026-09-15

Desktop access recovered. The retry used the same implementation with Claude Code
2.1.271. In the standard terminal mode, an actual Computer Use wheel action moved
into scrollback during a 250-line response. The pane retained `native.working`
while raw screen evidence was Idle. It then reached native Idle while the viewport
still showed the beginning of the response; the heuristic Idle wait resolved.
Screenshots and CLI samples are retained locally under
`.local/agent-screen-captures/claude-provider-wheel-20260915/`.

The isolated launch initially omitted user settings, so this case exercised normal
terminal scrollback. A second pane explicitly enabled `tui: fullscreen` to match
the original overlay case. Computer Use wheel calls did not move that viewer in
either direction. At this retry, the fullscreen overlay case remained unverified; successful wheel
calls alone are not evidence of viewer movement.

The retry passed `make check` (158 script tests) and `make build-app` (zero errors
or warnings). No implementation changes were needed. The fullscreen test pane was
left open for the requested manual scroll; the original cleanup statement above
applies to the earlier run.


### Acceptance decision on 2026-09-15

After the desktop retry, onevcat explicitly removed the separate fullscreen case
from required acceptance. The standard scrollback result closes the requested
wheel check. Fullscreen overlay scrolling was not verified; this decision does not
establish equivalent behavior experimentally. The implementation requires no change.
At closeout, the owned Debug PID had exited, its dedicated socket was absent, and
no test-cwd native registry files remained. See [001 action log](001-action.md).
