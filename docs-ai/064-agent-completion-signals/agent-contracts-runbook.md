# Agent Contract Checks — Maintainer Runbook

Living guide for #726 T1. Last researched: **2026-09-05**.
Design and initial machine inventory: [064.016](016-t1-contract-test-plan.md).

## Availability

`make test-agent-contracts` provides zero-inference inventory, Codex configuration preflight,
and an opt-in **eight-runtime contract verification and explicit attestation publisher**.
Seven routes use the owner's DeepSeek key; Qoder uses the account's explicitly selected Flash
model. `verify` combines configuration, supported zero-turn lifecycle, and headless model-turn
scenarios. `publish` advances only the verified rows in T0 and the generated research matrix.
GUI permission handling and workflow E2E belong to D2; reports keep `release_ready: false`.

The [release checklist](../001-fork-bootstrap-and-release-pipeline/release-runbook.md#agent-contract-release-check)
and `/release` skill require these checks before bump/tag and surface the evidence during
release-notes confirmation. See the scoped results in [064.016](016-t1-contract-test-plan.md).

## Required verification and publication

```bash
# Full T1 suite: eight short model turns, configuration and supported zero-turn checks.
make test-agent-contracts AGENT_CONTRACT_ARGS="--mode verify"

# Publish the successful report path printed by that command; no model requests.
make test-agent-contracts AGENT_CONTRACT_ARGS="--mode publish --report build/agent-contracts/run-EXAMPLE/report.json"

# Confirm the updated version baseline and generated matrix separately.
make agent-versions AGENT_VERSIONS_ARGS=--strict
make agent-versions AGENT_VERSIONS_ARGS=--check-matrix

# After a runtime-only upgrade, verify and publish just that runtime.
make test-agent-contracts AGENT_CONTRACT_ARGS="--mode verify --runtime pi"
```

Each sweep builds an opt-in Swift export test against the current source, reusing Xcode's
incremental build. That test uses Prowl's headless adapters and managed hook preparer, including
Droid's file merge. The runner then starts each real binary in a temporary workspace with its
prepared argv and the bundled hook bridge/extension. A private Unix socket captures frames
**decoded by the real Prowl CLI**. Temporary state is removed on normal completion or exception.
Droid and Qoder may read their normal account credentials; no normal runtime settings are edited.

A headless pass requires a correct answer to a fresh arithmetic challenge (the answer is absent
from the prompt), exit code 0, and every required native event in order, matching the launch
token, runtime, working directory, and one nonempty session ID. Directory aliases are compared
by canonical path. Requirements are fixed independently of the production decoder:

| Runtime | Required headless native events, in order | Zero-turn scenario |
| --- | --- | --- |
| Claude | `SessionStart`, `Stop`, `SessionEnd` | Empty prompt: start/end plus the known missing-input exit 1 |
| Codex | `agent-turn-complete` | Not applicable: native notifier has no session lifecycle |
| Copilot | `SessionStart`, `Stop`, `SessionEnd` | Not applicable: empty prompt rejected before session |
| Droid | `SessionStart`, `Stop`, `SessionEnd` | Not applicable: empty prompt exits without lifecycle |
| Qoder | `SessionStart`, `Stop`, `SessionEnd` | Not applicable: empty prompt has no session start |
| Pi | `session_start`, `agent_settled`, `session_shutdown` | Empty prompt: start/shutdown, exit 0, no response |
| OMP | `session_start`, `session_stop` | Not applicable: empty prompt can start a model turn |
| OpenCode | `session.idle` | Not applicable: native plugin has no session lifecycle |

OMP's one-shot host can exit before its queued shutdown relay starts. A two-second relay drain
still did not consistently deliver shutdown; the headless contract requires start/stop and
validates shutdown if received. This does not attest OMP interactive shutdown. Never run an
empty OMP prompt as a zero-inference check. Codex additionally runs all configuration scenarios
listed below. Unsupported zero-turn scenarios have fixed reasons; they cannot excuse a missing
required headless event.
A native error/StopFailure or a hook after failed authentication cannot pass. The collector
does not validate the GUI app's process ancestry, pane ownership, or lifecycle store; those
require interactive E2E and must not be inferred from this report.

`verify` returns 0 only when every selected runtime passes every required scenario, with
`contract_passed: true` and stable source fingerprints. `live` remains a diagnostic mode that
checks model turns only; its reports cannot be published. Live mode returns 0 only if
**every selected runtime** passes. Missing routes, unsupported
recipes, failed preparation, missing responses/hooks, runtime failures, and timeouts remain
visible in `report.json` and return nonzero. The report includes exact versions, source and
bridge fingerprints, route metadata, observed native events, and sanitized per-runtime logs.
Build receipts require a fresh nonce and exactly one executed, passed, non-skipped export test.
Do not publish raw logs; review the sanitized evidence before sharing it.

Launches are serial, with one short turn per runtime, no harness retries, a default 90-second
deadline (`--live-timeout`), and process-group cleanup. Supported clients get 512-token output
limits and low/off reasoning; Codex and Pi/OMP limits are not universal hard billing caps.
Actual billed usage is not collected. A time limit is not a provider-side spend limit.
Ordinary inventory, preflight, and `make check` never request inference.

### Publication and repetition

Before every release, run the full `verify` suite and explicitly `publish` its successful report
before bump/tag. Also repeat after changing runtime adapters, hook resources/decoding, model
routes, or runtime versions. For ordinary unrelated edits, offline checks suffice; a runtime-only
upgrade may use `--runtime`. A subset pass updates only that subset and never claims all-eight
coverage. Review and commit the generated receipt, baseline, and matrix with the change.

Publication requires a current-revision `verify` report completed within 24 hours, unchanged
source/bridge fingerprints, the same installed binary/version and policy route, all hashed
artifacts, and the original non-skipped Xcode result bundles. Keep the entire local run directory
until publication. Missing/failed scenarios, old `live` reports, modified evidence, and zero-test
results fail before writes. An invalid report returns 2; rerun verification after correcting its
cause. Publication runs version probes but never loads the credential file or calls a model.

The publisher writes an immutable, sanitized `attestations/<sha256>.json` receipt, advances T0's
version/date/record for selected runtimes, and regenerates the research matrix line. Replaying
the same eligible report is idempotent. It preserves the original Profile/interactive baseline
in `agent-attestation-interactive.json`; a headless receipt explicitly says
`interactive_verified: false`. Raw logs, local paths, hook tokens, and credential values do not
belong in the durable receipt. This is local evidence validation, not a cryptographic attestation
against an adversary who can rewrite both the report and artifacts.

## Available now: repeatable zero-inference checks

Run from the repository root:

```bash
# No model requests, no Xcode build; inventory all eight runtimes.
make test-agent-contracts

# Machine-readable report for one runtime; repeat --runtime to select more.
make test-agent-contracts AGENT_CONTRACT_ARGS="--runtime codex --json"

# Validate the example policy and report credential-reference presence only.
make test-agent-contracts AGENT_CONTRACT_ARGS="--config Config/agent-contracts.example.json"

# Real Codex config/read through production Swift code; no model or credentials needed.
make test-agent-contracts AGENT_CONTRACT_ARGS="--mode preflight --runtime codex"

# Existing version evidence and synthetic relay regressions.
make agent-versions AGENT_VERSIONS_ARGS=--check-matrix
python3 -m unittest discover -s scripts -p test_agent_hooks.py
```

`AGENT_CONTRACT_ARGS` is the Makefile argument variable. For paths containing shell-special
characters, call `python3 scripts/agent_contracts.py` directly with ordinary quoted arguments.
Every run keeps a unique owner-only directory under `build/agent-contracts/`, containing
`report.json`; `--output-dir` chooses another parent. JSON stdout includes `report_path`.
Preflight also retains a build log, `.xcresult`, nonce-bound receipt, and test summary.

Inventory reads installed versions and credential presence from the environment/private file.
It does not inspect agent auth stores, refresh tokens, query models, test credit, or change
settings. Login-shell PATH lookup is the same fallback as T0; `--no-login-shell` disables it.
Agent version subprocesses receive a small environment allowlist, excluding provider keys
and the parent pane/workflow identity. A newer version is drift evidence, not a failed version
read and not a newly attested contract.

Exit codes: inventory normally returns 0 after producing its report, even when entries are
blocked. `--strict` requires every selected binary to be readable and its route's credential
reference to be present (or explicitly keyless); drift alone is allowed. Preflight returns 0
only when every selected preflight passes, otherwise 1. T1a implements preflight only for
Codex, so select `--runtime codex`; other runtimes report `not_run`. Invalid configuration or
report I/O returns 2. A passed preflight still has `release_ready: false` and live `not_run`.
These are Python entry-point exit codes; `make` normally maps a failed recipe to exit 2.

The preflight forwards `TEST_RUNNER_` variables explicitly and requires exactly one passed,
non-skipped test plus a receipt matching this run's nonce and executable. It checks base
notify, an absent notifier, profile override, explicit override, project exclusion, and temporary parser cleanup.
The first execution may build the app/test host; subsequent executions use Xcode incremental
builds. `--preflight-timeout` defaults to 600 seconds including the build; `--timeout` bounds
individual version commands (20 seconds by default). No background model turn is started.

### Local model policy

The optional default is `~/.prowl/agent-contracts.json`. A missing default is reported as
`not_configured`; an explicit `--config` path must exist. Start from
`Config/agent-contracts.example.json`, which describes the owner's DeepSeek routes
for seven runtimes. Qoder is intentionally absent because its route is account-specific.

Schema 1 accepts only `schema` and a `runtimes` object keyed by the eight runtime IDs. Each
route requires `provider`, `model`, `base_url`, `wire_api`, and `api_key_env`. The model is an
explicit wire model ID, not a runtime-local alias such as Droid's `custom:...`; the live recipes
translate the policy into client settings. Protocol values are `responses`,
`chat-completions`, or `anthropic-messages`. `api_key_env` names an environment variable; null
means an explicitly keyless endpoint. Secret values, helper commands, unknown fields,
duplicate fields, auto-model routing, and credential-bearing URLs are rejected. HTTPS is
required except for loopback HTTP. Live recipes additionally check protocol compatibility;
keyless live recipes are not implemented.

The optional private key file is `~/.prowl/agent-contracts.env`; `--credentials` selects another
file. Create it with mode **0600**. It accepts literal `NAME=value` lines, optional matching
quotes, blank lines, and comments. Duplicate names, shell syntax, symlinks, foreign ownership,
and group/world access are rejected. Never `source` it. Exported environment values take
precedence. Only the selected route's key reaches a live child; version probes and Xcode
receive no provider keys. Keep this file outside repositories and never pass a key in argv.

`configured` means a valid route and a present credential reference, not successful auth.
The owner's scratch `.env` was moved here with equality verification and then removed.

Qoder may use a catalog-selected runtime-managed route after checking `qodercli --list-models`:

```json
{
  "provider": "qoder",
  "model": "deepseek/deepseek-v4-flash-pg",
  "base_url": null,
  "wire_api": "runtime-managed",
  "api_key_env": null
}
```

This is an entry under `runtimes.qodercli`, not a direct-provider API recipe. It uses Qoder's
existing account/model registration and billing. It does not prove that the supplied DeepSeek
key is used. The committed example omits it because availability is account-specific; this
machine's private policy includes the successfully tested route. For your own BYOK model,
register it through `/model` → Custom and use its exact model ID. Do not invent Qoder settings.

## Provider policy

**Default: the owner's existing DeepSeek V4 Flash provider access.** The owner confirmed its
marginal cost is negligible. Optimize for repeatability and shared configuration; do not add
free-model hunting, catalog refresh, or local model hosting to the required T1 implementation.
The free candidates below are research references for runtimes that cannot use this route.

Separate the runtime being tested from the model serving its turn. Select an exact provider,
model, and API protocol before starting. Do not mutate the user's ordinary global defaults.
Use per-run flags/environment or a disposable runtime config root; preserve only the selected
auth reference. If isolation requires credential copying or a login, document that setup
explicitly rather than cloning an entire agent home.

| Runtime | Preferred low-cost candidate | Configuration route and remaining proof |
| --- | --- | --- |
| Claude Code | `deepseek-v4-flash` | DeepSeek's Anthropic endpoint through per-process environment and explicit model; official integration exists [1]. Pin helper models too; verify current client handshake. |
| Codex | `deepseek-v4-flash` | Native custom provider using Responses, an isolated model catalog if required, and environment-key auth [2][3]. Direct Responses inference and the real notifier passed locally. |
| Copilot | `deepseek-v4-flash` | `COPILOT_PROVIDER_*` environment, `COPILOT_MODEL`; Chat Completions supports streaming/tools and BYOK needs no GitHub login according to installed help [4]. |
| Droid | `custom:deepseek-v4-flash` | Already in this machine's catalog; `customModels`, `generic-chat-completion-api`, `-m` [5]. Scoped settings merge and inference passed on this machine; a Factory account may still be required. |
| Qoder | Flash if available to this account | Local catalog lists `deepseek/deepseek-v4-flash-pg`; billing is unverified. `--model` accepts custom model IDs. Official BYOK setup is the `/model` Custom wizard; providers and access are account-dependent [6]. Do not invent a settings schema. |
| Pi | Explicit DeepSeek Flash provider/model | `models.json` supports OpenAI-compatible providers; select with `--provider`/`--model` [7]. Verified with a temporary provider; Pi 0.85 requires `${DEEPSEEK_API_KEY}`, not a bare variable name. |
| OMP | Explicit DeepSeek Flash provider/model | Custom `models.yml` provider plus `--model`; isolated profile/config and broker credentials need verification [8]. Verified with temporary `PI_CODING_AGENT_DIR` and `models.yml`. |
| OpenCode | DeepSeek Flash; optional explicit Zen free model | `-m provider/model`, custom provider configuration or Zen catalog [9][10]. Verify plugin loading is retained in the isolated setup. |

All eight selected routes passed the headless contract on this machine. This is not an
entitlement promise for other accounts; inventory alone still cannot establish usable credit.

### Cost baseline and free alternatives

As checked on 2026-09-05, the official DeepSeek Flash alias points to V4-Flash-0731. Rates per
million tokens are $0.22 input cache miss / $0.66 output off-peak, and $0.44 / $1.32 peak;
cached input is cheaper [11]. For planning, eight turns of **10,000 uncached input + 256 total
output tokens each** would cost approximately **$0.019 off-peak / $0.038 peak**. This is an
illustrative calculation, not measured usage or a cap: system prompts, reasoning, helper
requests, retries, and E2E tool loops can increase it. Recheck prices before a sweep.

DeepSeek exposes Chat Completions, Anthropic, and Responses, but the protocols are not
interchangeable. Its Responses API is stateless and does not support `previous_response_id`;
its `developer` role semantics and supported tools also differ [12]. Pin a tested client
configuration rather than treating "OpenAI-compatible" as sufficient.

Free candidates: Zen currently lists `opencode/big-pickle` and
`opencode/mimo-v2.5-free`, among others [10]. OpenRouter also offers explicit `:free` variants
and a random free router [13]. Confirm current availability, tools/streaming support, and
auth requirements; do not silently select another model or fall back to paid inference.
Record the chosen backend. Some free services use requests for model improvement [10], so
use only synthetic test fixtures. Local Ollama/LM Studio is another candidate if already
installed with a compatible model; model downloads and a persistent server are optional setup.

The public catalogs were also queried without credentials or inference on 2026-09-05:
[OpenRouter's model list](https://openrouter.ai/api/v1/models) returned 19 `:free` entries with
zero advertised prompt/completion price, including `nvidia/nemotron-3.5-lightning:free` with
tool support advertised. [Zen's model list](https://opencode.ai/zen/v1/models) included
`deepseek-v4-flash-free`, which is worth checking first for a free Flash route. A catalog ID
does not establish entitlement, sustained availability, or successful inference; confirm its
pricing and access before use. This alternative is deferred while the owner's existing
DeepSeek route works. Catalog refresh is outside the required T1 scope and the offline gate.

## Repetition and remaining acceptance

- During ordinary development, run offline regressions and select one live runtime when its
  adapter, provider recipe, or installed binary changes.
- After shared renderer/decoder/CLI/relay changes, rerun affected runtimes; before each public
  release, run the full headless command plus the Codex configuration preflight above.
- Inspect failures before retrying. A retry creates a new private report and does not erase
  earlier evidence. Do not silently change models or remove a runtime from the release scope.
- Keep the headless report separate from T0's interactive attestation. Publication with a
  scenario-aware schema and interactive needs-input/session lifecycle acceptance still needs
  implementation. Do not update all T0 version rows based on a headless sweep.
- D2 must run the bundled workflow skill through a Debug Prowl instance; use the
  [S3c acceptance record](011-s3c-action.md) and the
  [workflow release cadence](../063-agent-workflows/release-plan.md#cadence-and-working-rules).
  This headless suite does not replace D2's GUI/workflow protocol acceptance.

Missing accounts remain explicit blockers. Only the owner can approve a release-scope
exception; autonomous implementation authorization is not a waiver of release acceptance.

## Maintaining the harness

Keep a common process/capture/report implementation and thin runtime adapters. Add adapters
only for supported runtimes; avoid a plugin framework. Check actual test IDs/counts and
required artifacts so Xcode environment forwarding cannot yield a green zero-test run.
Keep the current synthetic relay tests for exhaustive event/error cases. Consider a local
fake inference endpoint only after measuring live-suite cost and reusing existing protocol
fixtures; mark that evidence simulated and keep a small live-provider canary.

## Official references (checked 2026-09-05)

1. [DeepSeek: Claude Code integration](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code/)
2. [OpenAI: advanced Codex configuration](https://developers.openai.com/codex/config-advanced/)
3. [DeepSeek: Codex integration](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/)
4. [GitHub: Copilot CLI BYOK](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models)
5. [Factory: custom models](https://docs.factory.ai/model-independence/byok)
6. [Qoder: custom models](https://docs.qoder.com/cli/custom-models)
7. [Pi: custom models](https://pi.dev/docs/latest/models)
8. [OMP: providers](https://github.com/can1357/oh-my-pi/blob/main/docs/providers.md)
9. [OpenCode: providers](https://opencode.ai/docs/providers/)
10. [OpenCode Zen: models, pricing, and data policies](https://opencode.ai/docs/zen/)
11. [DeepSeek: current pricing](https://api-docs.deepseek.com/quick_start/pricing/)
12. [DeepSeek: Responses API boundaries](https://api-docs.deepseek.com/guides/responses_api/)
13. [OpenRouter: free variants](https://openrouter.ai/docs/guides/routing/model-variants/free) and [limits](https://openrouter.ai/docs/api_reference/limits)
