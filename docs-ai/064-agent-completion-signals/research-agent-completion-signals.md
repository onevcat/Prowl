# Agent completion signals — per-runtime research (living)

> Living document for [064](000-plan.md): which deterministic "turn complete / needs
> input / session start-end" channels each recognized agent CLI offers, how they can be
> enabled per launch, what the payload carries, and what is not achievable. Update rows in
> place when a CLI changes; record the version and verification method per row. The tier-A
> versions the managed-hook contract is attested against live in
> [agent-attestation.json](agent-attestation.json), which generates the line below; the dated
> re-attestation paragraphs are history.

**Tier-A attestation** (generated from [agent-attestation.json](agent-attestation.json) by `scripts/agent_versions.py --write-matrix`; `make test-scripts` fails when this line drifts): claude 2.1.260 · codex 0.153.4 · copilot 1.0.83 · droid 0.210.0 · qodercli 1.1.31 · pi 0.85.1 · omp 18.1.10 · opencode 1.18.25 — last live sweep 2026-09-05 ([attestations/0a584feae25749f1cb6079fd990d0d1147eb8ea803a6ed9ba0b8b3bc6c8407d1.json](attestations/0a584feae25749f1cb6079fd990d0d1147eb8ea803a6ed9ba0b8b3bc6c8407d1.json)).

**S3c re-attestation (2026-08-26):** Pi 0.84.3 · Oh My Pi 18.0.6 · OpenCode 1.18.23 (all upgraded first;
see [010-s3c-plan.md](010-s3c-plan.md) for the measured lifecycles).

**S3a re-attestation (2026-08-24):** Claude Code 2.1.241 · Codex CLI 0.149.0 · Pi 0.84.2.
Claude final repeated `--settings` wins and retained the documented payloads. Codex's official
app-server `config/read` returns effective base/CLI `notify`, excludes project `notify` even for
a trusted project, and profile-v2 lives at `$CODEX_HOME/<name>.config.toml`; app-server rejects
`--profile`. Codex accepts `-C dir`, `--cd dir`, `--cd=dir`, and `-Cdir`, but rejects repeated cwd
options rather than applying last-wins. See [007-s3a-action.md](007-s3a-action.md).

**Baseline (2026-08-22, this Mac):** claude 2.1.239 · codex 0.147.0 · gemini 0.46.0 ·
cursor-agent 2026.05.09 · cline 3.0.48→3.0.56 · opencode 1.18.11 · copilot 1.0.77 ·
kimi 1.41.0 · droid 0.186.0 · amp 0.0.1783746383 · qodercli 1.0.48 · qwen 0.21.3 ·
grok 0.2.118 · pi 0.84.2 · omp 17.2.7.

**Method:** `--help`; string search over binaries/bundles; read-only inspection of each
tool's session directory; official docs; and, where auth allowed, a live non-interactive
run with a capture hook (a script appending argv + stdin JSON to a scratch log) to prove
per-launch enablement and real payloads. Live hook runs succeeded for claude, codex,
copilot, kimi, droid, pi, omp, opencode; partially for qodercli (SessionStart/End), qwen
(SessionStart), amp (session.start/agent.start); blocked by login for gemini,
cursor-agent, cline; not attempted for grok (no per-launch channel). No user config files
were modified; all runs used scratch directories and per-launch flags/env.

Confidence: **V** verified locally (live run or binary/source) · **D** official docs ·
**C** community · **?** unknown.

## 1. Summary matrix

| Runtime | Turn-complete signal | Blocked / permission signal | Per-launch enablement (exact) | Payload: session id / last message | OSC self-report | Transcript marker | Conf. |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Claude Code | hooks `Stop` (`StopFailure` on API error); `SessionStart` / `SessionEnd` | hooks `PermissionRequest` (immediate); `Notification` `notification_type` = `permission_prompt` (~6 s after prompt), `idle_prompt` (~60 s), `elicitation_dialog`; `Elicitation` | `claude --settings '<json>'` or `--settings file.json` (hooks MERGE with user hooks) — live-verified; `--session-id <uuid>`; `CLAUDE_CONFIG_DIR` = full relocation | stdin JSON: `session_id`, `cwd`, `transcript_path`, `permission_mode`, `last_assistant_message` (Stop) | `preferredNotifChannel` auto/iterm2(OSC 9)/kitty/ghostty/terminal_bell — same idle/permission gating; OSC 9;4 via `terminalProgressBarEnabled` | `~/.claude/projects/<enc-cwd>/<id>.jsonl`: assistant `stop_reason:"end_turn"` then `system/turn_duration` | V |
| Codex | `notify=[…]` → `agent-turn-complete`; hooks `Stop`; `SessionStart` / `SessionEnd` | hooks `PermissionRequest`; nothing for idle | `-c 'notify=["/abs/cmd"]'` (no trust gate) — live-verified; `-c 'hooks.Stop=[{hooks=[{type="command",command="/abs/cmd"}]}]'` fires ONLY with `--dangerously-bypass-hook-trust` (else silently skipped) — both live-verified; `CODEX_HOME` = full relocation | notify: JSON as last argv: `thread-id`, `turn-id`, `cwd`, `last-assistant-message`; hooks stdin: `session_id`, `turn_id`, `transcript_path`, `cwd`, `last_assistant_message` | `tui.notifications` (+ `tui.notification_method` osc9/bel, `tui.notification_condition` unfocused default / always); no 9;4 | `~/.codex/sessions/Y/M/D/rollout-*.jsonl`: `event_msg` `task_complete` / `turn_aborted` | V |
| Gemini CLI | hooks `AfterAgent` (once per turn); `SessionStart` / `SessionEnd` | hooks `Notification` `notification_type:"ToolPermission"` only; no idle/ask hook | no `--settings` flag; project `.gemini/settings.json`; `GEMINI_CLI_SYSTEM_SETTINGS_PATH=/file.json` (system layer, merges) — untested; `GEMINI_CLI_HOME` = full relocation | stdin JSON: `session_id`, `transcript_path`, `cwd`, `prompt_response` (AfterAgent) | off by default: `general.enableNotifications` + `notificationMethod` auto/osc9/osc777/bell; no 9;4 | `~/.gemini/tmp/<hash>/chats/session-*.jsonl` (no explicit marker) | D + bundle |
| Cursor Agent | hooks `stop` (`status` completed/aborted/error), `afterAgentResponse` (`text`); `sessionStart` / `sessionEnd` | none (Claude-compat map sets `PermissionRequest→null`, `Notification→null`) | no flag/env (`CURSOR_CONFIG_DIR` does not move hooks.json); project `<workspace>/.cursor/hooks.json` or `.claude/settings(.local).json`; `--plugin-dir` hooks not executed in this build | stdin JSON: `conversation_id`/`session_id`, `transcript_path`, `workspace_roots`, `text` | `cli-config.json` `notifications:true`: focus-gated → OSC 9 (iTerm2), OSC 777 (Ghostty/Warp), OSC 99 (Kitty), BEL (Terminal.app); no 9;4 | `~/.cursor/projects/<slug>/agent-transcripts/<chatId>/<chatId>.jsonl` (no marker) | V (bundle) |
| Cline | file hooks `TaskComplete` (=`agent_end`), `TaskError`, `TaskCancel`; `TaskStart` / `SessionShutdown` | none | dirs `~/.cline/hooks`, `<cwd>/.cline/hooks`, `<cwd>/.clinerules/hooks`; `--hooks-dir <path>` only sets `CLINE_HOOKS_DIR`, no reader found → unverified; `CLINE_DIR` = full relocation | stdin JSON: `taskId`, `hookName`, `workspaceRoots`, `turn.outputText`; no transcript path | none | `~/.cline/data/tasks/<taskId>/ui_messages.json`: `say:completion_result` → `ask:completion_result`; any `type:"ask"` = waiting | V (source) |
| OpenCode | plugin `event`: `session.idle` (once per top-level turn; fires even after `session.error`, occasionally twice), `session.status {type:"idle"}`; `session.created` / `session.deleted`; SSE `GET /event` | `permission.asked` (until `permission.replied`), `question.asked` (until `question.replied`) — both measured with a real dialog on screen (1.18.23); **`--auto` with a `permission: ask` config emits `permission.asked` + `permission.replied{reply:"once"}` in the same millisecond with nobody waiting**; the default (allow) config emits no `permission.asked` | `OPENCODE_CONFIG_CONTENT='{"plugin":["file:///abs/probe.ts"]}'` — live-verified; loaded as a `"local"` config layer whose `plugin[]` **concatenates** with project/global lists (measured 1.18.23); project `.opencode/plugins/*.ts` — live-verified; `OPENCODE_CONFIG=/file.json`; `--pure` or `OPENCODE_PURE=1` disables every external plugin; a missing plugin path is ignored | in-process `{type, properties:{sessionID,…}}`; `session.created.properties.info.parentID` marks sub-agent sessions, whose own `session.idle` fires before the parent's; `message.updated` `finish:"stop"` | only `tui.attention` (default disabled): OSC 99/777 when blurred | `~/.local/share/opencode/opencode.db` message `time.completed` / `finish:"stop"`; `session.parent_id` marks sub-agent rows | V |
| Copilot CLI | hooks `agentStop` (`stopReason:"end_turn"`); `sessionStart` / `sessionEnd` | hooks `notification` `notification_type` `permission_prompt`, `elicitation_dialog`; `permissionRequest` | `--plugin-dir <dir>` (`plugin.json` + `hooks.json`) — live-verified; `COPILOT_PLUGIN_DIR_ONLY=1`; repo `.github/hooks/*.json` (trust-gated); `COPILOT_HOME` = full relocation | stdin JSON: `sessionId`, `cwd`, `transcriptPath`, `stopReason`; no last message | `terminalProgress` OSC 9;4 (default on); `beep` BEL (off); `notifications` toast (off) | `~/.copilot/session-state/<id>/events.jsonl`: `assistant.turn_end`, `session.shutdown` | V |
| Kimi CLI | `[[hooks]]` `Stop` (`StopFailure`); `SessionStart` / `SessionEnd` | none in hooks; `wire.jsonl` `ApprovalRequest` + BEL | `--config-file FILE` / `--config '<toml/json>'` REPLACE the whole config (must include providers) — live-verified with a full copy; `KIMI_SHARE_DIR` = full relocation | stdin JSON: `hook_event_name`, `session_id`, `cwd`, `stop_hook_active`; no transcript / last message | BEL on approval/question only | `~/.kimi/sessions/<md5 cwd>/<id>/wire.jsonl`: `TurnEnd`; `ApprovalRequest` = blocked | V |
| Factory Droid | hooks `Stop`; `SessionStart` / `SessionEnd` | hooks `Notification` `permission_prompt`, `idle_prompt`, `elicitation_dialog` | `--settings /abs/file.json` (merged for this process only), also on `droid exec` — live-verified | stdin JSON: `session_id`, `transcript_path`, `cwd`, `permission_mode`; no last message | OSC 9;4 only when `TERM_PROGRAM` contains ghostty; `completionSound` / `awaitingInputSound` (`bell` = BEL) | `~/.factory/sessions/<enc-cwd>/<id>.jsonl` (no explicit marker) | V |
| Amp | plugin `agent.end` (`status` done/error/cancelled, `messages[]`); `session.start` | no event; in-process `ctx.thread.state` idle/running/awaiting-approval/error | project `.amp/plugins/*.ts` or `~/.config/amp/plugins/` only (no flag/env) — project load live-verified; `--settings-file` REPLACES user settings | in-process: `thread.id`, `messages`; no cwd field | `amp.notifications.enabled` (default on): local sounds; BEL only over SSH/`AMP_FORCE_BEL`; OSC 777 when unfocused | server-side threads; local files are stubs → unreliable | V + D |
| Qoder CLI | hooks `Stop` (`last_assistant_message`), `StopFailure`; `SessionStart` / `SessionEnd` | hooks `PermissionRequest`, `PermissionDenied`, `Notification` `permission_prompt` (not focus-gated), `idle_prompt` (focus-gated), `elicitation_dialog`, `Elicitation` | `--settings '<json>'` or `--settings file.json` (highest priority) — live-verified (both forms); **flag hooks ARE trust-gated**: in an untrusted folder Qoder 1.1.29 refuses them with `Security: Blocked execution of hook (system) in untrusted folder` (corrected 2026-08-25; the earlier "not trust-gated" reading came from probing an already-trusted directory); `--config-dir` / `QODER_CONFIG_DIR`; `--setting-sources` drops flag hooks | stdin JSON: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `agent_id` | `general.enableNotifications` (default false): OSC 9 else BEL, unfocused only; no 9;4 | `~/.qoder/projects/<enc-cwd>/<id>.jsonl`: assistant `stop_reason:"end_turn"` | V |
| Qwen Code | hooks `Stop` (`last_assistant_message`), `StopFailure`; `SessionStart` / `SessionEnd` | hooks `PermissionRequest`, `PermissionDenied`, `Notification` `permission_prompt`, `idle_prompt` (not focus-gated) | no flag; project `.qwen/settings.json` — live-verified; `QWEN_CODE_SYSTEM_SETTINGS_PATH` exists but did NOT fire hooks in test; `QWEN_HOME` = full relocation | stdin JSON: `session_id`, `transcript_path`, `cwd`, `timestamp`, `permission_mode`, `model` | `general.terminalBell` (default true): OSC 9/99/777/BEL, unfocused only; completion only after ≥20 s turns | `~/.qwen/projects/<enc-cwd>/chats/<id>.jsonl` + `<id>.runtime.json` (pid); no turn marker in 0.21.3 | V |
| Grok Build | hooks `Stop` (`reason:"end_turn"`, `lastAssistantMessage`); `[[ui.notifications.hooks]]` on `turn_complete`; `SessionStart` / `SessionEnd` | hooks `Notification` (`permission_prompt`, `idle_prompt`), `PermissionDenied`; `[[ui.notifications.hooks]]` `approval_required` | NO flag/env on the TUI (`GROK_HOME` relocates incl. auth); `~/.grok/hooks/*.json`, trusted `<project>/.grok/hooks/*.json`, Claude/Cursor-compat files | stdin JSON camelCase: `sessionId`, `cwd`, `lastAssistantMessage`; env `GROK_SESSION_ID`, `GROK_EVENT`, `GROK_MESSAGE` | default ON but focus-gated: OSC 777/9/99/BEL; OSC 9;4 `progress_bar=true` | `~/.grok/sessions/<urlenc-cwd>/<id>/updates.jsonl` `turn_completed`; `events.jsonl` `permission_requested`, `turn_ended` | D + binary |
| Pi | extension `agent_end` → `agent_settled` (idle; 0.84.3 measured: `session_start{reason:startup}` → `input` → `turn_start` → `agent_start` → `turn_end` → `agent_end` → `agent_settled`); `session_start` (`reason` startup/new/resume/fork/reload) / `session_shutdown` (`reason` quit/new); `/new` = `session_shutdown{new}` + `session_start{new}` with a new id | none (no permission system) | `pi -e /abs/ext.ts` — live-verified; additive, survives `--no-extensions`, loads before `project_trust`, read-only dir OK; **a missing `-e` path aborts startup**; `PI_CODING_AGENT_DIR` = full relocation | in-process: `ctx.sessionManager.getSessionId()` (= UUID in the session file name) / `getSessionFile()`, `ctx.cwd` (resolved), `agent_end.messages`; extensions may `spawn` (Node) | none by default; OSC 9;4 if `terminal.showTerminalProgress`; OSC 133 | `~/.pi/agent/sessions/--<enc>--/<ts>_<id>.jsonl`: assistant `stopReason:"stop"` | V |
| Oh My Pi | extension `session_stop` (documented main-session only; once per prompt; Claude-`Stop`-shaped payload `session_id`/`turn_id`/`stop_hook_active`/`last_assistant_message`) — `agent_end` also fires **per in-process `task` sub-agent** (3× for one sub-agent, 18.0.6), with an undocumented `willContinue` that measured `undefined`; `session_start` at startup only, `/new` = `session_before_switch` → `session_switch` (new id), `session_shutdown` at exit | `tool_approval_requested` {`sessionId`,`toolName`,`toolCallId`,`approvalMode`} / `tool_approval_resolved` {…,`approved`} — fires with the built-in TUI approval prompt under `--approval-mode always-ask` (default config `yolo`); `ask` tool → built-in notification only | `omp --hook /abs/ext.ts` (or `-e`, identical) — live-verified; additive, survives `--no-extensions`; missing path warns and continues; `--config overlay.yml` (repeatable); `--profile` isolates auth+sessions | in-process: `ctx.sessionManager.getSessionId()`, `ctx.cwd` (**logical** shell path, e.g. `/tmp/…`), in-process `task` sub-agents run under their **own** session ids (file nested in the parent's session directory, `<ts>_<parent>/<Agent>.jsonl`) and fire their own `session_start` / `agent_end`; their handlers see `ctx.hasUI == false` / `ctx.mode == "print"` and run in a **fresh extension module instance** per sub-agent session (same process, shared `globalThis`) | default ON: OSC 9/99/BEL; `PI_NOTIFICATIONS=off`; OSC 9;4 if `terminal.showProgress` | `~/.omp/agent/sessions/<enc>/<ts>_<id>.jsonl`: assistant `stopReason:"stop"`; `custom/session_exit` | V |

## 2. Per-runtime notes (abridged; sources)

- **Claude Code** — https://code.claude.com/docs/en/hooks , https://code.claude.com/docs/en/terminal-config.
  `Stop` fires when the main agent finishes (not on interrupt). Live: `claude -p … --settings
  '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/abs/capture.sh"}]}],…}}'`
  fired SessionStart → Stop → SessionEnd; payload includes `transcript_path`,
  `last_assistant_message`, `permission_mode`. Env: `CLAUDE_PROJECT_DIR`,
  `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`. Caveat (docs): interactive sessions hold all hooks
  until the workspace-trust dialog is accepted.
- **Codex** — https://learn.chatgpt.com/docs/hooks.md ,
  https://learn.chatgpt.com/docs/config-file/config-advanced.md#notifications. Live:
  `codex exec -c 'notify=["/abs/capture.sh","tag"]'` fired `agent-turn-complete` (payload as
  last argv incl. `last-assistant-message`); `-c hooks.*` fired only with
  `--dangerously-bypass-hook-trust`. S3a's 0.149 re-attestation pinned app-server
  initialize/`config/read`, base/profile-v2/final-CLI notifier precedence, project-notify
  exclusion, and repeated-cwd rejection. An internal "memories" sub-session (cwd
  `~/.codex/memories`, `transcript_path:null`) also fires SessionStart/End — filter on cwd.
  App-server note (0.149.1, 2026-08-25): `codex app-server --listen stdio://` exits on stdin EOF
  and drops requests it has not answered yet; keep the request pipe open until the response
  arrives (0.149.0 still answered queued requests after EOF).
- **Gemini CLI** — https://geminicli.com/docs/hooks/reference/ ,
  https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/notifications.md. Hooks
  merge across user/project/system layers; project hooks are fingerprinted/trust-warned.
- **Cursor Agent** — https://cursor.com/docs/agent/hooks. `stop` only fires when a
  user/project `hooks.json` defines it; plugin hooks run only in builds ≥ 2026-08-11.
- **Cline** — https://docs.cline.bot/customization/hooks.md. The Claude-style hook list in
  the binary is a bundled Claude settings schema, not Cline hooks.
- **OpenCode** — https://opencode.ai/docs/plugins , https://opencode.ai/docs/server. Live:
  `session.status {busy}` → … → `session.status {idle}` + `session.idle` (fires even after a
  model error). `opencode serve` exposes SSE `GET /event`. 1.18.23: the TUI creates its
  session at the first prompt, `/new` and resume emit nothing until then; the TUI is one
  process while `opencode run` forks an engine child that hosts plugins.
- **Copilot CLI** — https://docs.github.com/en/copilot/reference/hooks-reference. Live:
  `copilot -p … --plugin-dir <dir>` (`plugin.json` + `hooks.json`) fired
  sessionStart / agentStop / sessionEnd; `--session-id` makes the transcript path
  deterministic.
- **Kimi CLI** — https://moonshotai.github.io/kimi-cli/en/customization/hooks.html.
  `--config-file` replaces the whole config (no merge): a Prowl-generated copy must
  re-supply the user's providers.
- **Factory Droid** — https://docs.factory.ai/reference/hooks-reference. Live:
  `droid exec --settings /abs/settings.json` fired SessionStart/Stop/SessionEnd (Stop even
  though the exec failed). Process shape (0.203.0, 2026-08-25): the interactive TUI is one
  `droid` process, and once the folder is trusted it forks a second `droid exec
  --input-format stream-jsonrpc --output-format stream-jsonrpc` engine in the same process
  group; every hook (`bash -c`) is a child of that engine, so a hook's ancestry contains both
  processes. Prowl's process probe lists the newer engine first and identifies it once it
  exists.
- **Amp** — https://ampcode.com/manual/plugin-api. Plugins only from project
  `.amp/plugins/` or `~/.config/amp/plugins/`; `ctx.thread.state` exposes
  `awaiting-approval` in-process.
- **Qoder CLI** — https://docs.qoder.com/cli/hooks. Live: `--settings` inline JSON and
  file both fired SessionStart/End (quota error before Stop). Corrected 2026-08-25: flag hooks
  **are** trust-gated. A first launch in a folder Qoder has not been told to trust logs
  `Security: Blocked execution of hook (system) in untrusted folder` and fires nothing; once the
  folder is trusted the same launch reaches `verified_live`. The original probe ran in a
  directory that had already been trusted interactively, which hid this.
- **Qwen Code** — https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/. Live:
  project `.qwen/settings.json` fired SessionStart; `QWEN_CODE_SYSTEM_SETTINGS_PATH` did not.
- **Grok Build** — https://docs.x.ai/build/features/hooks ,
  https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md.
  No per-launch flag on the TUI; `--plugin-dir` only on `grok agent` (ACP).
- **Pi** — https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md.
  Live: `pi -e /abs/probe.ts -p …` → session_start → agent_start → turn_start → turn_end →
  agent_end → agent_settled → session_shutdown.
- **Oh My Pi** — https://github.com/can1357/oh-my-pi/blob/master/docs/extensions.md. Live:
  `omp --hook /abs/probe.ts -p …` → session_start → … → session_stop → agent_end →
  session_shutdown. Session dirs use hashed names in 17.2.5–17.2.8. 18.0.6: first launch shows
  a one-step setup wizard; `--print` blocks in `readPipedInput` while a non-TTY stdin stays open.

## 3. What is not achievable (as of the baseline)

**No per-launch injection without touching global config or a file inside the user's
project:** Grok Build (TUI), Cursor Agent, Amp, Cline (`--hooks-dir` unverified), Gemini
and Qwen (project settings only; system-settings env untested / did not fire), Kimi (only
by replacing the whole config), Codex hooks beyond `notify` (trust bypass flag required).

**No native "blocked / waiting for input" channel:** Cursor Agent, Cline, Kimi (hooks),
Amp (event), Pi (no permission system), Codex idle between turns, Gemini beyond
`ToolPermission`, OMP `ask`.

**Last assistant message in the payload** only for Claude Code, Codex, Grok, Gemini
(`prompt_response`), Cursor (`afterAgentResponse.text`), Cline (`turn.outputText`),
Amp/Pi/OMP/OpenCode (in-process messages), Qoder/Qwen (docs). Not in Copilot `agentStop`,
Droid `Stop`, Kimi `Stop`.

**Terminal escapes are never a deterministic channel:** every runtime gates its OSC
9/99/777/BEL on focus, idle thresholds, or opt-in settings; OSC 9;4 progress (where
emitted) separates working from not-working but not blocked from idle.

**No usable local transcript with a turn marker:** Amp (server-side). Weak/no explicit
marker: Gemini, Cursor, Droid, Qwen 0.21.3, Cline, Pi/OMP (infer from assistant
`stopReason`).

## 4. Implications for Prowl (feeds 064 §Design / S3)

| Tier | Runtimes | Channel Prowl can attach at launch |
| --- | --- | --- |
| **A — flag/env per launch, no user config touched** | Claude Code (`--settings`), Codex (`-c notify=[…]`, turn-complete only), Copilot CLI (`--plugin-dir`), Factory Droid (`--settings`), Qoder CLI (`--settings`), Pi (`-e`), Oh My Pi (`--hook`), OpenCode (`OPENCODE_CONFIG_CONTENT`) | `signalHooks = .launchFlag` — first S3 wave |
| **B — requires a Prowl-owned home** | Gemini (`GEMINI_CLI_HOME`), Qwen (`QWEN_HOME`), Grok (`GROK_HOME`), Cline (`CLINE_DIR`), Kimi (`KIMI_SHARE_DIR`; or full-config replacement) | unsupported for managed hooks; Prowl does not write hook configuration into dedicated homes |
| **C — project files only** | Cursor Agent (`<workspace>/.cursor/hooks.json`), Amp (`.amp/plugins/`) | unsupported for managed hooks; Prowl does not write into the user's project |

S3 has no second wave. Only tier A receives Prowl-managed hooks; tiers B and C remain on
cooperative, transcript/process, OSC, or heuristic evidence.

Within supported tier A, managed blocked/permission coverage is available for Claude,
Copilot, Droid, Qoder, and OpenCode; OMP requires an approval handler. Codex's permission
hooks are trust-gated and therefore omitted, while Pi has no permission system. Native hook
capabilities in unsupported tiers remain research facts only and are not Prowl-managed.

Payloads with `last_assistant_message` (Claude, Codex, Qoder, Qwen, Grok, Gemini) let 063's
V2 observe mode capture a result without transcript parsing for those runtimes.
