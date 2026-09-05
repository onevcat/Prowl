# 064.015 — T0 Version Attestation: Plan and Action

## Status

Implemented from `feat/agent-version-attestation` as the T0 half of
[#726](https://github.com/onevcat/Prowl/issues/726) (R2a in the shared
[release plan](../063-agent-workflows/release-plan.md)). T1 — headless contract tests against
the real binaries, `make test-agent-contracts` — is a later slice and is not started here.

## Scope

The managed hooks shipped by S3 wave 1 ([007](007-s3a-action.md), [009](009-s3b-action.md),
[011](011-s3c-action.md)) are a contract with eight external binaries, and three drifts found
while closing S3b (Droid's `droid exec` engine child, Codex 0.149.1's app-server EOF behavior,
Qoder's folder-trust gate on flag hooks) were invisible to the unit suite. T0 makes the
*version* side of that contract explicit and cheap to check:

- an attestation record that says, per tier-A runtime, which version the contract last passed a
  live sweep against, when, and where that is recorded;
- `make agent-versions`, which compares the binaries installed on this Mac with the record;
- the research matrix's tier-A baseline derived from the record instead of hand-edited.

Non-goals: running any agent (T1), the optional scheduled npm/brew "latest" check from the issue
(nothing in the repo runs on a schedule yet; revisit with T1), and touching the interactive E2E
sweep.

## The record

`agent-attestation.json` (next to the research matrix), schema 1:

| Key | Meaning |
| --- | --- |
| `schema` | `1`; the loader rejects anything else |
| `description` | free text for readers of the file |
| `runtimes[]` | one object per tier-A runtime, in the S3 order claude, codex, copilot, droid, qodercli, pi, omp, opencode |
| `runtimes[].runtime` | `AgentProfileRuntime` raw value (`qodercli`, not `qoder`) |
| `runtimes[].name` | display name |
| `runtimes[].binary` | executable looked up on PATH |
| `runtimes[].version_command` | argv that prints the version, e.g. `["claude", "--version"]`; the first element must be the binary |
| `runtimes[].attested_version` | the version the live sweep passed against; must parse as `MAJOR.MINOR.PATCH[-pre]` |
| `runtimes[].attested_on` | ISO date of that sweep |
| `runtimes[].record` | the `docs-ai/064` file that documents the sweep; must exist next to the JSON |

Every key is required and no other key is allowed, so a typo fails `make test-scripts` rather
than silently going unread. T1 now advances these fields through an explicit `--mode publish`
operation after `--mode verify`; follow the [runbook](agent-contracts-runbook.md). Publication
preserves entry schema 1 and links immutable, scoped headless evidence. The original interactive
baseline is archived in `agent-attestation-interactive.json`; headless publication never advances
that archive or implies a new Profile/GUI acceptance. The provenance below describes the original
T0 sweep, not the current headless baseline.

### Attested versions and their provenance

The original eight entries pointed at the S3c live acceptance in [011-s3c-action.md](011-s3c-action.md),
the last sweep that exercised every tier-A runtime through a Prowl-launched Profile: Pi 0.84.3,
Oh My Pi 18.0.6, OpenCode 1.18.23, plus the "regression on the same build" row for Claude
2.1.245, Codex 0.149.1, Copilot 1.0.80, Droid 0.203.0, and Qoder 1.1.29 (PASS ×5). Two
ambiguities, resolved as follows:

- 011 carries no explicit date. `attested_on` is 2026-08-26, the day PR #728 was opened with that
  record (merged 2026-08-27); the same five versions had already passed 009's upgrade
  re-verification on 2026-08-25, so the date is bounded either way.
- [013](013-idle-evidence-fallback.md) exercised Claude live again on 2026-08-28/29 but never
  states the binary version, so Claude stays at the last explicitly verified 2.1.245 rather than
  the 2.1.251 installed when this record was written.

## Decisions

| Decision | Rejected alternatives |
| --- | --- |
| One generic semantic-version parser (first `MAJOR.MINOR.PATCH[-pre]` token in stdout, else stderr, ANSI stripped) pinned by tests to the verbatim banner each of the eight CLIs printed on 2026-08-29. | Per-CLI parsers keyed by runtime: more code to maintain for no measured gain — every banner (`2.1.251 (Claude Code)`, `codex-cli 0.149.1`, `GitHub Copilot CLI 1.0.80.` + an update hint, `omp/18.0.6`, bare versions) yields the right token with one pattern, and the tests fail loudly if a banner changes. |
| Binary lookup on the process PATH first, then once on the PATH of `$SHELL -lic` for anything still missing; a version command runs with the PATH it was found on. | Process PATH only: `make` run from an editor or agent harness misses Homebrew and `mise` tools (measured on this Mac: a bare PATH plus `zsh -lc` sees 9 entries and no `/opt/homebrew/bin`; `zsh -lic` sees 34 with Homebrew and mise). `mise which` per binary: only covers mise, and none of the eight is mise-managed here. Login-only (`-lc`): skips `.zshrc`, which is where Homebrew's `shellenv` and `mise activate` live on a stock macOS setup. |
| A missing binary is a warning; nothing fails without `--strict`. `--strict` fails on any status but `attested`. | Failing on missing by default: a machine without every agent installed is normal, and the pre-release use is "look at the table", not a gate. |
| The matrix keeps its dated re-attestation paragraphs as history and gains one generated `**Tier-A attestation**` line; `--check-matrix` compares that line with the record and prints a per-runtime diff, `--write-matrix` regenerates it, and `make test-scripts` runs the check. | Rewriting the research paragraphs from the record: they are evidence about specific dates and would lose meaning. Deleting the line and pointing at the JSON only: readers of the matrix would have to open a second file for the one number they ask most often. |
| No `docs/` change: `make agent-versions` is a maintainer tool, so it is listed in `CLAUDE.md`'s build commands and here, not in the agent-facing manual. | — |

## Delivered behavior

- `docs-ai/064-agent-completion-signals/agent-attestation.json` — the record above.
- `scripts/agent_versions.py` + `make agent-versions` (`AGENT_VERSIONS_ARGS="--json"`,
  `"--strict"`, `"--check-matrix"`, `"--write-matrix"`, `"--timeout N"`, `"--no-login-shell"`):
  prints `runtime / attested / installed / status` with status one of `attested`, `newer`,
  `older`, `missing`, `unparseable`; `newer` warns with a hint to run `make test-agent-contracts`
  (T1) and update the record on a pass; `missing` and `unparseable` warn with the resolved path
  or the first output line; the exit code is 0 unless `--strict`. `--json` emits, per runtime,
  the attestation fields plus `path`, `resolution` (`path` / `login-shell`), `installed_version`,
  `raw_output`, `status`, `detail`, and a `summary` count per status.
- `research-agent-completion-signals.md` — intro sentence naming the record as the source of
  the tier-A versions, and the generated line.
- `scripts/test_agent_versions.py` (32 tests, run by `make test-scripts` and therefore `make
  check`): parsers against the captured banners, comparison including prerelease ordering, the
  record's shape and tier-A coverage, every status through a fake resolver/runner, the shell
  PATH fallback through a stub shell, JSON and table shapes, strict exit codes, the matrix check
  against the committed files and against tampered copies, and the script end to end with stub
  binaries on a private PATH.

## Verification

- `make test-scripts`: 76 tests, OK (44 before this slice plus the 32 in `test_agent_versions.py`).
- `make agent-versions` on this Mac, 2026-08-29:

  ```
  runtime   attested  installed  status
  claude    2.1.245   2.1.251    newer
  codex     0.149.1   0.149.1    attested
  copilot   1.0.80    1.0.80     attested
  droid     0.203.0   0.204.0    newer
  qodercli  1.1.29    1.1.31     newer
  pi        0.84.3    0.84.3     attested
  omp       18.0.6    18.0.6     attested
  opencode  1.18.23   1.18.23    attested
  warning: claude 2.1.251 is newer than the attested 2.1.245 (011-s3c-action.md, 2026-08-26); the managed-hook contract is unverified against it — run `make test-agent-contracts` (#726 T1) and update docs-ai/064-agent-completion-signals/agent-attestation.json on a pass
  warning: droid 0.204.0 is newer than the attested 0.203.0 (…)
  warning: qodercli 1.1.31 is newer than the attested 1.1.29 (…)
  ```

  Three runtimes have moved past their attestation since the S3c sweep; that is exactly the
  signal T0 exists to surface, and T1 is what clears it.
- `make agent-versions AGENT_VERSIONS_ARGS=--json`: summary `attested 5, newer 3, older 0,
  missing 0, unparseable 0`; every binary resolved on the process PATH.
- `make agent-versions AGENT_VERSIONS_ARGS=--check-matrix`: `research-agent-completion-signals.md
  matches agent-attestation.json`, exit 0. `--strict` exits 1 from the script (`make` reports 2).
- Shell fallback, with PATH reduced to `/usr/bin:/bin`: all eight resolved as `login-shell`
  (`~/.local/bin` and `/opt/homebrew/bin`) with the same statuses; with `--no-login-shell` all
  eight are `missing`. A login-only shell had found just the three under `~/.local/bin`, which is
  what settled `-lic`.
- `make check`: format-changed (no Swift changes), format-lint, lint, test-scripts all pass.

## What T1 builds on

- The record is the place a passing `make test-agent-contracts` writes to: per runtime, set
  `attested_version` to the version it just passed against, `attested_on` to today, and `record`
  to the T1 record, then regenerate the matrix line.
- `scripts/agent_versions.py` exposes `load_attestation`, `parse_version`, `compare_versions`,
  and `BinaryResolver`, so T1 can reuse the same binary lookup and version parsing to name the
  exact build each contract ran against, and `--strict` gives a release gate once every runtime is
  attested.
- The `newer` warning text already names T1's target so nothing has to change when it lands.

## Observed but not changed

- `/opt/homebrew/bin/droid` is a stale cask symlink to 0.134.0, shadowed by `~/.local/bin/droid`
  0.204.0 from Factory's installer. First-on-PATH wins here, as it does in a shell, so the report
  shows 0.204.0; the cask is left alone.
- The release runbook has no pre-release checklist section to hang `make agent-versions` on; the
  release skill and runbook are unchanged.
