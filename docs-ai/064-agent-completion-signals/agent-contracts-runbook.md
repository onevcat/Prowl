# Agent Contract Checks — Maintainer Runbook

Living guide for #726 T1. Last researched: **2026-09-05**.
Design and initial machine inventory: [064.016](016-t1-contract-test-plan.md).

## Availability

T0 and the commands in "Available now" exist. The unified inventory/preflight/live runner,
model policy, scoped attestation publication, and report format below are **planned**. Do not
invoke `make test-agent-contracts` yet or treat this document as a successful live sweep.
No model inference was performed for the initial inventory.

## Available now: repeatable zero-inference checks

Run from the repository root:

```bash
make agent-versions AGENT_VERSIONS_ARGS=--json
make agent-versions AGENT_VERSIONS_ARGS=--check-matrix
python3 -m unittest discover -s scripts -p test_agent_hooks.py
```

The first command compares installed versions with previous evidence; newer/missing is a
warning, not a new attestation. Add `--strict` when equality with the recorded baseline is
required. The second checks generated documentation consistency. The third exercises shipped
relays with synthetic runtime events; it does not launch the real agents.

Recheck local flags with `--help`, including `codex exec --help`, `droid exec --help`,
`opencode run --help`, and `copilot help providers`. Never use a model prompt as a help probe.
For credential inventory, emit only allowlisted readiness fields. `claude auth status` and
`codex login status` can report login state; Pi has the following non-refreshing check:

```bash
pi auth check --provider deepseek --json --no-refresh
```

Do not add `--credentials` or use `print-api-key`, `print-bearer-token`, or `omp token` in
captured diagnostic output. A credential file's absence is inconclusive for Keychain/broker
auth. A `ready` result checks local credential resolution, not remaining credit or inference.

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
| Codex | `deepseek-v4-flash` | Native custom provider using Responses, an isolated model catalog if required, and environment-key auth [2][3]. Direct DeepSeek support now exists; current local execution remains untested. |
| Copilot | `deepseek-v4-flash` | `COPILOT_PROVIDER_*` environment, `COPILOT_MODEL`; Chat Completions supports streaming/tools and BYOK needs no GitHub login according to installed help [4]. |
| Droid | `custom:deepseek-v4-flash` | Already in this machine's catalog; `customModels`, `generic-chat-completion-api`, `-m` [5]. Validate scoped settings merge and account requirement before using it as a reusable recipe. |
| Qoder | Flash if available to this account | Local catalog lists `deepseek/deepseek-v4-flash-pg`; billing is unverified. `--model` accepts custom model IDs. Official BYOK setup is the `/model` Custom wizard; providers and access are account-dependent [6]. Do not invent a settings schema. |
| Pi | Explicit DeepSeek Flash provider/model | `models.json` supports OpenAI-compatible providers; select with `--provider`/`--model` [7]. This machine resolves a DeepSeek credential; verify exact model metadata and request once. |
| OMP | Explicit DeepSeek Flash provider/model | Custom `models.yml` provider plus `--model`; isolated profile/config and broker credentials need verification [8]. No confirmed usable DeepSeek route on this machine yet. |
| OpenCode | DeepSeek Flash; optional explicit Zen free model | `-m provider/model`, custom provider configuration or Zen catalog [9][10]. Verify plugin loading is retained in the isolated setup. |

The candidates above are documentation/configuration evidence, not eight successful model
connections. BYOK may remove the need for a runtime subscription, but account gates and
provider credits still need checking. Never infer entitlement from a model appearing in help.

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

### Proposed budget controls

- Inventory/preflight must not issue inference, even when credentials happen to be present.
- Live mode requires an explicit model route. Keep credentials out of argv/logs and committed
  configuration; use existing sanctioned environment/key-store references.
- Start serially, one short turn per runtime, no tools for the hook-only scenario, no automatic
  harness retry. Disable unrelated plugins/MCP/background work without disabling Prowl hooks.
- Request a small supported output limit (initial target 256); select low/off reasoning where
  supported. If a runtime cannot enforce a limit, say so in its plan/report before execution.
- Initial proposed deadline: 60 seconds per live attempt. Stop owned child processes on
  timeout/cancel. Report provider usage when available, otherwise `unknown`, never zero.
- Treat a per-sweep USD estimate as a planning bound. Only a provider-side spend limit or a
  verified runtime budget control is a hard cap; elapsed-time limits are not billing controls.

## Proposed operating sequence once T1 is implemented

The implementation must add exact tested command lines here. These are steps, not commands
available today:

1. Inventory selected runtimes, exact executable paths/versions, auth readiness, model routes,
   hook-resource/source fingerprints, and build-product freshness. Stop before inference.
2. Run zero-inference preflight. Show unsupported scenarios and access blockers individually.
3. Run a selected live contract using a synthetic directory and a fresh capture socket.
   Require successful inference plus the expected correlated hook frame, not just process exit.
4. Inspect the report. Preserve errors such as authentication, credit, trust, missing hook,
   decode mismatch, timeout, and provider outage separately. Never clear a failure by retrying
   invisibly or swapping the model.
5. After a runtime upgrade, rerun that runtime. After shared renderer/decoder/CLI/relay changes,
   rerun all affected runtimes. Before release, require all eight mandated runtime routes.
6. Publish attestation only after required scenarios pass, explicitly and per runtime. Link
   durable sanitized evidence; keep preflight/headless/interactive coverage distinguishable.
7. Drive D2 from the bundled skill through an isolated Debug Prowl instance. Use the
   [S3c acceptance record](011-s3c-action.md) for the existing interactive setup and the
   [workflow release cadence](../063-agent-workflows/release-plan.md#cadence-and-working-rules).
   Synthetic workflow/tool-delivery checks precede any review of real repository content.

Normal development can run one runtime without the other seven subscriptions. A missing
account produces a useful blocked result, but never a full-gate success. If access cannot be
obtained, record an explicit release-scope decision instead of weakening assertions.

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
