# 064.016 — T1 Repeatable Runtime Contract Tests

| | |
| --- | --- |
| **Status** | T1 implemented and verified 2026-09-05; scoped baseline published; merge pending; D2 GUI acceptance remains separate |
| **Anchor date** | 2026-09-05 |
| **Primary PR** | [#767](https://github.com/onevcat/Prowl/pull/767) (T1a) |
| **Related** | [#726](https://github.com/onevcat/Prowl/issues/726), [T0](015-t0-version-attestation.md), [release plan](../063-agent-workflows/release-plan.md), [operating runbook](agent-contracts-runbook.md) |

## Decision to make

Keep T1 before D2, with a small reusable runner and runtime-specific probes. Default to
zero-inference inventory; require an explicit live mode for one short model turn per selected
runtime. Use the owner's existing DeepSeek V4 Flash access wherever supported. The owner
confirmed its marginal cost is negligible, so maintaining free-model discovery is not a T1
deliverable. Free hosted or already-installed local models are alternatives only when a
runtime cannot use that DeepSeek route, never implicit fallbacks.

The owner approved autonomous T1a implementation after the inventory and route review.
T1a implements inventory, a strict secret-free model policy, reports, and the production
Codex configuration preflight. It does not change production hook semantics or claim the
live release gate passed. Default inventory needs no Xcode build or model request; explicit
preflight builds/runs the existing Swift test through the repository's Xcode setup.

## Verified starting point

Inventory used checkout `cce270c4` on `agent-workflow-r2b`, CLI help, T0's version checker,
credential-presence checks, and the official references in the runbook. No inference request,
subscription purchase, login, credential refresh, or global configuration edit was performed.
Authentication diagnostics were reduced to status fields; no credential values were printed.

| Runtime | Installed | T0 attested | Headless entry confirmed by local help | Local access evidence |
| --- | --- | --- | --- | --- |
| Claude Code | 2.1.260 | 2.1.245 | `claude -p`, `--model` | `auth status`: logged in, first-party Max; allowance untested |
| Codex | 0.153.2 | 0.149.1 | `codex exec -m`, custom provider/config, `--oss` | `login status`: logged in; allowance untested |
| Copilot | 1.0.83 | 1.0.80 | `copilot -p`, `--model`, provider environment | Local provider help confirms BYOK needs no GitHub login; provider key absent from this process |
| Droid | 0.210.0 | 0.203.0 | `droid exec -m` | Help lists `custom:deepseek-v4-flash`; local config targets the official DeepSeek endpoint and has a credential field; validity untested |
| Qoder | 1.1.31 | 1.1.29 | `qodercli -p`, `--model`, `--list-models` | Catalog exits successfully and lists `deepseek/deepseek-v4-flash-pg`; entitlement, billing route, custom setup, and inference untested |
| Pi | 0.85.0 | 0.84.3 | `pi -p --provider --model` | DeepSeek credential entry exists; `auth check --no-refresh` returns `ready`; balance/inference untested |
| Oh My Pi | 18.1.10 | 18.0.6 | `omp -p --model`, `--profile`, config overlay | Installed/configured; broker/provider readiness unverified; absence of legacy `auth.json` proves nothing |
| OpenCode | 1.18.25 | 1.18.23 | `opencode run -m provider/model` | Credential store and config exist; selected provider access and free-model availability unverified |

All eight versions are newer than the attestation. No relevant provider API key was exported
in this process, including DeepSeek and OpenRouter; this does not imply keys are unavailable
in agent stores, a broker, Keychain, or another launch environment. Do not copy credentials
between agent stores as part of inventory.

Existing reusable boundaries:

- `scripts/agent_versions.py`: binary lookup, login-shell fallback, version parsing, T0 record.
- `supacode/Domain/AgentRuntime/AgentRuntimeAdapter.swift`: existing `.headless` invocation
  support; reuse it rather than maintaining test-only launch command templates.
- `supacode/Domain/AgentRuntime/AgentManagedHookPreparer.swift` and
  `ManagedHookRendering.swift`: production launch/configuration preparation.
- `Resources/agent-hooks/`: actual Pi/OMP/OpenCode relays; preserve their relative layout with
  the bundled CLI, because extensions resolve `../../prowl-cli/prowl` themselves.
- `supacode/CLIService/Shared/AgentNativeHookPayload.swift`: production event decoding.
- `supacodeTests/CodexConfigReadLiveContractTests.swift`: existing real-binary preflight,
  now supplied the resolved executable and nonce-bound receipt location by the unified entry point.
- `scripts/test_agent_hooks.py`: zero-inference relay tests against simulated runtime events;
  useful regression coverage, not proof that a real runtime emits those events.
- `Makefile`: test result/count checks and reusable build products. There is no
  live contract runner beyond T1a inventory/preflight.

## Evidence boundaries

| Mode | What it proves | What it cannot attest |
| --- | --- | --- |
| Inventory | Binary/version, supported flags, credential presence/readiness, selected model configuration | Account balance, successful inference, hook delivery |
| Preflight | Real configuration loading; Codex `config/read`; lifecycle events only where independently triggerable | Successful turn completion or interactive launch |
| Live contract | Real binary + production hook preparation/relay/CLI + captured socket frame, with a successful short turn | Prowl process attribution, trust UX, terminal rendering, workflow correctness |
| Interactive E2E | Prowl Profile launch, admission/attribution, trust handling, D2 delivery/loop/watchdog | Every other runtime/provider combination |

Build the live harness in the existing Swift test target so it can call production preparation
directly. A thin Python entry point owns runtime selection, version resolution, report
aggregation, timeouts, and optional attestation publication; it must not reimplement hook
rendering/decoding. Reuse compiled products with `test-without-building` when their source
and resource fingerprints match; do not create another public CLI or standalone framework.

Use the real bundled CLI against a temporary Unix socket that implements the minimal response
contract. Assert the actual decoded frame. The stub socket intentionally does not claim to
test the app's authorization/ancestry store. A successful exit alone, a synthetic hook call,
or an API-error `StopFailure` is insufficient for a live pass: require successful inference
and the expected runtime event correlated to this probe's cwd/session.

Give each probe a fresh hook token and its own socket endpoint. Remove inherited workflow,
dispatch, and pane identity from the child environment so a nested probe cannot deliver into
the coordinating session. Keep only the selected auth route and necessary runtime variables.

## Runtime expectations

Use the production decoder's capabilities as the source, with explicit scenario expectations
so an accidental removal of a required event cannot shrink the tests silently.

| Runtime family | Main-turn signal expected by Prowl | Additional focus |
| --- | --- | --- |
| Claude / Droid / Qoder | `Stop` | Applicable `SessionStart`/`SessionEnd`; Qoder trust prerequisite; failed requests must not count as success |
| Copilot | `Stop` in the production hook configuration/decoder | Local plugin loading and applicable session events |
| Codex | `agent-turn-complete` | Production notify/preflight path; do not switch to different hooks to simplify the test |
| Pi | `agent_settled` | Startup/shutdown and relay drain before process exit |
| OMP | `session_stop` | Main-session semantics; subagent filtering remains covered by existing relay tests and targeted E2E |
| OpenCode | `session.idle` | Successful main session; no fabricated session-start/end requirement |

Do not assume every lifecycle event can be obtained without a model or account. Discover this
per runtime in the implementation spike. An unsupported scenario differs from a missing
event that the contract requires. Preserve app launch flags; make headless adaptations small
and record their difference from the interactive route.

## Repetition, cost, and results

- Keep runtime adapters separate from local credential/model policy. A local config selects
  exact provider/model IDs, auth references, wire protocol, supported token/effort limits,
  and deadlines; commit only a secret-free example once implemented.
- Default that policy to the owner's DeepSeek access across compatible runtimes. Verify each
  client uses the intended endpoint and billing route; a similarly named hosted Flash model
  is not evidence that it uses the owner's existing provider account.
- Use a synthetic temporary workspace outside the repository. Disable unrelated discovery,
  MCP, tools, and background model features where supported, while retaining Prowl's hooks.
  D2's synthetic E2E explicitly enables only the tools needed to deliver through the CLI.
- Default to one short prompt, no automatic model fallback, no harness retries, and serial
  live probes. Pin low/off reasoning only where the selected model supports it. Bound
  output and runtime retries where possible; always bound elapsed time and clean up the
  probe-owned process group. A timeout does not cancel provider billing already incurred.
- Report runtime version/path, source and hook-resource fingerprints, provider/model/protocol,
  execution mode, expected/observed events, test counts, elapsed time, and available usage.
  Retain sanitized artifacts locally; never store tokens or full inherited environments.
- Distinguish `passed`, `contract_failed`, `blocked` (install/auth/credit/trust/provider),
  `timed_out`, and `not_run`. Inventory readiness must not become a live pass. Preserve every
  attempt; classify an infrastructure retry separately instead of erasing the first result.
- Default runs do not edit T0. An explicit publish operation may update only runtimes whose
  required live scenarios passed. Add scoped evidence references without erasing earlier
  interactive evidence; never let a partial probe bless a whole runtime. The exact backwards
  compatible T0 schema extension is part of T1 implementation, not this docs change.

## Delivery route

| Step | Scope | Exit condition |
| --- | --- | --- |
| T1a | Inventory/report skeleton, safe configuration contract, no-inference Codex preflight | Default invocation cannot call a model; missing credentials and zero executed tests are visible |
| T1b | Production end-to-end hook harness, first Codex/Droid/Pi adapters | Three distinct injection families pass on one explicitly selected low-cost route each; setup and usage are recorded |
| T1c | Copilot, Qoder, OMP, OpenCode, Claude adapters; scoped attestation, runbook commands, and release reminder integration | All eight are represented; required scenarios pass or report precise access blockers; publication rejects incomplete coverage; the release skill/runbook guide the maintainer through the implemented full-suite command and report |
| D2 gate | Full selected live suite, then the built-in workflow through a Debug app | Eight required runtime contracts pass on recorded routes, plus D2 E2E; any scope waiver requires an explicit release-plan decision |

These are implementation milestones inside #726 T1, not additional releases. If Qoder cannot
run with the available account, finish its adapter and report the blocker; do not purchase a
subscription or silently remove it from the gate. Local development may run a subset without
claiming release readiness.

The owner requested that release preparation actively remind them, rather than relying on
memory. The [release runbook](../001-fork-bootstrap-and-release-pipeline/release-runbook.md#agent-contract-release-check)
and `.claude/skills/release/SKILL.md` now carry the conditional reminder. T1's completion must
replace the contract runbook's planned operations with tested commands and verify that the
release instructions reach them before bump/tag and show the result during release approval.
This is maintainer guidance; no automatic gate in `scripts/release.sh` is implemented here.

## Alternatives and open questions

- A local fake inference server could give real-runtime hook coverage at zero token cost.
  Consider a bounded experiment after T1b, preferably reusing upstream fixtures. Do not build
  and maintain three API emulators before proving the small live suite. Label simulated
  inference separately; it never attests provider compatibility.
- A free-model router changes the model between runs. Prefer an explicit free ID and record
  the resolved backend where available. Hosted free capacity is opportunistic, not a stable
  release dependency. With the owner's inexpensive DeepSeek access, free-model catalog
  discovery and local model setup are deferred unless a runtime needs an alternative route.
- Confirm Qoder's current-account custom catalog, persisted model ID, and scoped trust setup.
- Confirm Droid BYOK still needs any Factory account/session in the tested launch mode.
- Confirm OMP's broker/profile isolation and all model clients' shutdown/relay-drain behavior.
- Confirm Codex's installed model-catalog schema against the official DeepSeek recipe; do not
  copy the recipe's embedded bearer token, global config replacement, or high-effort defaults.
- Confirm how each client caps total requests, helper models, and reasoning tokens. Cost
  estimates are not hard spend limits unless enforced by the runtime/provider.


## T1a implementation result (2026-09-05)

- `scripts/agent_contracts.py` and `make test-agent-contracts` now inventory selected runtimes
  (all eight by default), reuse T0 binary/version handling, and write a unique private JSON
  report. A valid version on a failing command does not count as a successful inventory.
- `Config/agent-contracts.example.json` describes proposed DeepSeek wire routes for seven
  runtimes; Qoder remains absent pending its account-specific configuration. Schema 1 permits
  only explicit model/provider/protocol/URL and environment-key references. Unknown/duplicate
  fields, embedded URL credentials, helper commands, and auto routing are rejected. Inventory
  checks presence only and never reads agent credential stores or copies a key.
- Explicit preflight calls the existing Swift production configuration resolver/process in
  `CodexConfigReadLiveContractTests`, with a temporary home and selected executable. The
  internal Makefile target forwards `TEST_RUNNER_` variables. A matching nonce/executable
  receipt and exactly one passed, non-skipped xcresult test are both required for success.
- Reports keep inventory, route readiness, preflight, and live states separate. `--strict`
  checks inventory/config readiness, not attestation equality. Unsupported preflights return
  `not_run` and a failing exit; no live mode or attestation publication is exposed.
- Default inventory has no build dependency. Preflight uses normal Xcode incremental `test`
  builds, rather than a new cache or standalone binary. Both modes avoid model requests.
  The process wrapper strips provider credentials and parent pane/workflow identity, applies
  deadlines, and terminates its process group on timeout/cancellation.
- The [runbook](agent-contracts-runbook.md), `AGENTS.md`, and release reminder now distinguish
  implemented inventory/preflight from the remaining live suite.

Verification: 22 new Python tests observed red then green; `make check` passed 104 script
tests plus Swift formatting/lint. All eight installed version probes succeeded and reported
newer-than-attested. Strict inventory with the example policy correctly reported a missing
credential reference. The real 0.153.2 configuration preflight passed one executed test with
zero skips/failures, including base/profile/explicit precedence, project exclusion, and scratch
cleanup. A requested Pi preflight correctly returned `not_run` and a failing exit. Reports
remain local under `build/agent-contracts/`; no attestation or credential configuration changed.
The full eight-runtime live gate and D2 E2E remain outstanding.

## Authorized live implementation (2026-09-05)

The owner supplied a DeepSeek key and authorized bounded inference and autonomous decisions.
Keep it in the owner-only `~/.prowl/agent-contracts.env`, outside the checkout; policy JSON
contains variable references only. Explicit environment variables take precedence. Never
source this file as shell code or copy credentials into test artifacts.

Implement a Swift opt-in exporter using the production headless adapters and managed hook
preparer, then a Python runner with a private workspace, per-launch token and Unix socket.
The real bundled CLI decodes native events before the socket collector accepts them. Require
both a successful model response and a matching terminal hook; process exit or an error hook
alone cannot pass. This checks the binary/renderer/extension/decoder boundary. It does not
claim GUI lifecycle, app-side caller ancestry, or interactive permission coverage.

Use temporary runtime configuration and the owner's selected DeepSeek route where supported.
Do not modify normal runtime settings or purchase subscriptions. Bound each launch and retain
sanitized evidence, including precise failures. Run all available runtimes, then use those
results to decide the remaining interactive coverage and attestation scope.


## Headless implementation and results (2026-09-05)

The opt-in suite passed all eight installed runtimes in `run-sf4oqfd8/report.json` under
`build/agent-contracts/`. Runtime execution took about 22 seconds total, excluding the
incremental export build. This is observed duration, not a latency or billing guarantee.

| Runtime | Version | Model route | Observed terminal event |
| --- | --- | --- | --- |
| Claude Code | 2.1.260 | Owner DeepSeek key, Anthropic Messages | `Stop` |
| Codex | 0.153.2 | Owner DeepSeek key, Responses | `agent-turn-complete` |
| Copilot | 1.0.83 | Owner DeepSeek key, Chat Completions | `Stop` |
| Droid | 0.210.0 | Owner DeepSeek key, scoped custom model/settings | `Stop` |
| Qoder | 1.1.31 | Existing account's `deepseek/deepseek-v4-flash-pg` | `Stop` |
| Pi | 0.85.0 | Owner DeepSeek key, temporary provider | `agent_settled` |
| OMP | 18.1.10 | Owner DeepSeek key, temporary provider | `session_stop` |
| OpenCode | 1.18.25 | Owner DeepSeek key, temporary provider/plugin | `session.idle` |

Every row also returned the correct fresh arithmetic response and exited successfully.
Qoder's route does not establish use of the supplied API key or free account billing.
No normal runtime settings were modified and no subscription was purchased. The private
credentials file is `~/.prowl/agent-contracts.env` (0600); the private policy is its `.json`
sibling. Reports and logs never contain the supplied key or the launch token.

The first sweep exposed a production bug: `CodexConfigReadProcess` used `try?` on an optional
return, collapsing a successful absent notifier into the same nil as an incomplete response.
A valid `notify: null` therefore waited until timeout and degraded managed hooks. The read loop
now treats any successful decode as complete and waits only on `missingResponse`. A real
process fixture reproduces both null and missing notify while the server keeps stdin open;
it failed before the fix, then the process/resolver suites passed 15 tests. The real Codex
preflight now also includes an absent-notifier scenario.

Two harness corrections came from live evidence: Pi 0.85 resolves `${KEY}` references but
interprets bare `KEY` as a literal, and OMP reports `/var` aliases of `/private/var` workspaces.
The failed Pi authentication still emitted a terminal hook, confirming why a hook alone
cannot pass. The collector now canonicalizes directory identity; the production OMP relay
needed no change. Optional whitespace in an otherwise correct numeric response is accepted.

T1b's three injection families and all eight headless T1c adapters are implemented. Remaining
T1 acceptance at that point still required scenario-aware attestation publication. Interactive
needs-input/GUI coverage belongs to D2, not #726 T1. The old T0 attestation was unchanged by #767. A headless all-pass report remains `release_ready: false`.

Final verification: a second full sweep, `run-0p_q17r_/report.json`, again passed 8/8 with
22.4 seconds of runtime execution. `run-hmnrrqgb/report.json` passed the expanded Codex
preflight, including absent notify. `make check` passed 115 script tests and strict Swift
format/lint; `make build-app` passed with zero errors/warnings. The release skill validator
passed. A supplied-key scan across report/source artifacts found zero matches. These local
reports remain under `build/agent-contracts/`; this record preserves their scoped conclusions.

## T1 closure implementation plan (2026-09-05)

The owner authorized the remaining headless contract and attestation work. Correct the earlier
scope expansion: #726 explicitly excludes GUI/interactive automation; that remains D2/release
acceptance, not a T1 implementation prerequisite.

- Define fixed per-runtime native event/mapping expectations, required lifecycle events where
  supported, one-session identity, and event order. Probe zero-turn lifecycle support with
  real binaries before declaring requirements; document unsupported native one-shot behavior.
- Add `--mode verify` to compose required preflight and live scenarios in one report. Default
  inventory remains free of inference. Missing required scenarios fail the aggregate gate.
- Add explicit `--mode publish --report PATH`: reject incomplete, failed, skipped, stale,
  changed-source, changed-binary, or mismatched-route evidence before writing any baseline.
  Persist sanitized immutable scenario records, update only the verified runtime rows, and
  regenerate the matrix. Preserve the legacy interactive baseline separately. Keep T0's
  entry schema; each linked evidence record states its scope instead of implying GUI coverage.
- Tests cover event identity/order and publication refusal/no-write paths. Run the real suite,
  publish its result, verify version/matrix agreement, then update the runbook and release
  guidance. No subscription purchase or changes to normal runtime configuration.


## T1 closure result (2026-09-05)

`--mode verify` now composes the configuration preflight, two supported zero-turn lifecycle
probes, and eight real short model turns. Required native events, mappings, session identity,
working directory, and order are fixed in `agent_contract_expectations.py`, independently of
the production decoder. `--mode live` remains diagnostic and cannot publish evidence.

Two complete verification sweeps passed (`run-qt4qpxlr`, then final `run-14n7jk2w`). The final
report passed 8/8 headless turns, Claude/Pi zero-turn lifecycle, and all five Codex configuration
scenarios through one executed, non-skipped preflight test. The launch exporter likewise ran
exactly one passed test. Versions and provider routes match the table above.

The discovery probe established that Copilot/Droid cannot emit a complete empty-prompt session,
Qoder only emits the end, and OMP may start inference on empty input. These are explicit
zero-turn exclusions, not skipped required scenarios. OMP headless reliably emits start/stop;
its host can exit before the queued shutdown relay starts, even with a two-second drain.
Shutdown is validated when received but is not attested by this headless contract. Full GUI
lifecycle and workflow admission/permission behavior remain D2's responsibility, as #726 excludes
interactive GUI automation.

`--mode publish --report PATH` revalidates fresh source/bridge and binary hashes, model policy,
scenario coverage, response logs, artifact hashes, nonce receipts, and original Xcode result
summaries before updating any baseline. Evidence expires after 24 hours. Publication writes a
sanitized immutable [headless receipt](attestations/c7b43b440b25c9b0c423886ad524e9fda377150b21edfc13487dcdbede8bd3d3.json),
updates selected T0 rows and the generated matrix, and preserves the original interactive
baseline in `agent-attestation-interactive.json`. This is local provenance validation, not a
signature against malicious report rewriting. No model request is made during publication.

Final publication advanced all eight versions; `make agent-versions --strict` (through
`AGENT_VERSIONS_ARGS=--strict`) and the separate matrix check passed. Replaying the report is
idempotent; older live evidence and the now-stale earlier verify report are rejected without
writes. The runbook and release skill now guide full verify/publication before bump/tag and
show T1 evidence separately from D2 during release confirmation. No global runtime settings
or subscriptions changed.

Validation after publication: `make check` passed 131 Python script tests and strict Swift
format/lint; `make build-app` passed with zero warnings/errors. The release skill validator
passed. The final report still matches the current source fingerprint. A scan of changed files
and final report artifacts found no occurrence of the supplied provider key. Publication tests
cover stale/partial reports, binary/route changes, artifact mutation, missing/zero-count receipts,
incorrect responses/events, subset preservation, idempotency, and rollback after a write failure.
