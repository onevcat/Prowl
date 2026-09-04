# 030.009 — Captured Screen Fixture Corpus and Baseline

> Amended by [014-claude-full-screen-live-block.md](014-claude-full-screen-live-block.md):
> the canonical-tail reduction below now applies to non-Claude fixtures only. Claude
> fixtures are committed as full active screens, bounded by the captured terminal rows.
>
> Extended by [015-deterministic-live-footer-coverage.md](015-deterministic-live-footer-coverage.md)
> with capture-derived Pi 0.85.0 and Codex 0.153.2 Working fixtures. Counts and benchmark
> numbers below remain the original Phase 2 baseline.

| | |
| --- | --- |
| **Status** | Implemented |
| **Anchor date** | 2026-08-07 |
| **Primary PR** | [#685](https://github.com/onevcat/Prowl/pull/685) |
| **Plan** | [007-screen-profile-migration-plan.md](007-screen-profile-migration-plan.md), Phase 2 |
| **Prerequisite** | [008-detector-faithful-cli-capture.md](008-detector-faithful-cli-capture.md) |

## Context

Inline screen literals test focused predicates well but cannot prove their CLI version,
capture source, terminal geometry, or redaction history. Phase 2 adds a capture-derived
regression corpus before changing production classification behavior.

## Corpus

The committed corpus contains 15 sanitized `prowl read --source detection` captures:

| Runtime | Version | Blocked | Working | Idle | Quarantine |
| --- | --- | --- | --- | --- | --- |
| Codex | 0.146.1 | directory trust, hook review, sign-in selection, command permission | foreground footer | composer, quoted directory-trust transcript | — |
| Claude | 2.1.223 | workspace trust, command permission | foreground spinner, active subagent, backgrounded subagent | composer, quoted permission transcript | history-search viewer |

All captures came from authenticated current CLIs in an isolated Debug Prowl instance and
private temporary workspaces. The terminal was 52 rows high and 106–132 columns wide.
Raw captures stayed under ignored `.local/agent-screen-captures/`; copied authentication
and state databases were removed after capture.

Each `.txt` is the canonical production tail produced by the shared
`agentDetectionRecentText` helper: it starts at the 24th non-empty line from the bottom
when at least 24 exist, otherwise retaining the whole screen, while preserving
internal/trailing blank terminal rows. Same-basename metadata
records schema version, exact CLI version, UTC capture timestamp from the raw file,
`prowl-read-detection` source, terminal geometry, and an explicit redaction summary.
Paths, account/organization identifiers, usage balances, real prompt history, private
persona output, and session IDs were replaced with synthetic placeholders. Purpose-built
probe prompts/output remain only where they provide conversational regression structure.
Right-edge terminal padding was removed without changing leading columns or wraps. A
corpus-specific `.gitattributes` rule preserves
intentional trailing blank screen rows without weakening whitespace checks elsewhere.

Reconstructed and synthetic screens remain inline in `ScreenHeuristicsTests`; no existing
literal was relabeled as a captured/versioned fixture.

## Harness and quarantine

`AgentScreenFixtureCorpusTests`:

- discovers fixtures relative to `#filePath` and asserts at least one ran;
- validates path layout, runtime/state tokens, metadata schema/source/version/timestamp,
  explicit issue key, terminal geometry, redaction summary, matching sidecars, no orphan
  metadata, and rejects every unexpected regular file;
- verifies each committed text is already the canonical detector tail through the same
  production helper used by `detectState(in:)`;
- runs every normal fixture through the current detector;
- asserts initial Claude/Codex blocked/working/idle lifecycle coverage;
- treats `known-misdetection/<expected>/<current>/...` as an executable quarantine.

Fresh capture exposed one current drift: Claude 2.1.223 history search now renders
`Search prompts · everywhere`, `⌕ Filter history…`, and `↑/↓ to nav ...` instead of the
older viewer hints. Product semantics require `.unknown`, but the current detector returns
`.idle`. The capture is committed under `known-misdetection/unknown/idle/` with issue #676.
Phase 2 asserts current behavior and does not hide a production fix inside test
infrastructure; the Claude profile phase must either promote it with a capture-backed fix
or leave the quarantine explicit.

The synchronized Xcode test group treats `Fixtures/` as an explicit folder so nested
runtime/version filenames retain hierarchy rather than flattening into duplicate resource
outputs. Tests intentionally read the source checkout; bundle resources are not an
alternate classifier path.

## Release baseline

`ScreenHeuristicsBenchmarks` classifies the complete 15-fixture corpus as changed-screen
input. `make bench` runs 20 corpora per timed sample, reports the median normalized to one
corpus, and applies no absolute CI threshold.

Final reviewed baseline at `cf6e6f04` on this M-series host:

- complete 15-fixture corpus: **3.142 ms median**;
- arithmetic per-fixture cost: **0.209 ms**;
- 15 Release timing samples; benchmark suite completed in 6.17 s on the warm build.

The first attempted 2,000-corpus sample was deliberately aborted after proving unsuitable
for a per-PR gate; the committed workload uses 20 and remains well above clock noise.
Future Codex/Claude profile PRs compare the same absolute metric and preserve the scan
cache, so this measures changed-frame classifier cost rather than steady-state polling.

## Validation

- Corpus tests: 4 passed; 15 screen fixtures and 15 metadata sidecars executed, plus
  unexpected-file and missing-issue-key failure paths.
- Screen benchmark Debug smoke: 1 passed.
- Full app suite: xcsift reported 2,278 passed; xcresult independently verified 2,280
  tests and zero failures.
- `make bench`: 6 benchmark tests passed; four existing Ghostty symbol-index warnings,
  zero errors/failures; screen corpus record appended successfully.
- `make check` and `make build-app` passed.
- Privacy audit found no user email/account, home path, OAuth URL/state, usage number,
  copied credential, or unredacted high-entropy session identifier. The only user-related
  URL is the intentional public #676 quarantine link.
- Metadata JSON parsed, fixture hashes were all distinct, every fixture held at most 24
  non-empty lines, raw staging was confirmed ignored, and `git diff --check` passed with
  the scoped fixture whitespace attribute.

## Result

Phase 2's exit condition is met. Current Claude/Codex shapes are versioned and explainable,
newly observed drift is visible rather than dropped, and profile migrations now have both
a behavior corpus and a reproducible Release performance baseline. Production detector
behavior remains unchanged.
