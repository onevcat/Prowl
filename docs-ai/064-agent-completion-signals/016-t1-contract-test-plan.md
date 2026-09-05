# 064.016 — T1 Repeatable Runtime Contract Tests

| | |
| --- | --- |
| **Status** | T1a implemented and verified 2026-09-05; T1b/T1c live contracts and inference verification remain pending |
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
