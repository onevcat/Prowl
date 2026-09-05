# Agent Profiles

> Named launch presets for every agent runtime Prowl recognizes: one click
> in the toolbar **Agents** menu or the Command Palette starts a fresh agent in
> the current worktree with your model, effort, mode, and — optionally — a
> dedicated account.

**Keywords:** agent profile, preset, launch agent, agents menu, dedicated home, account, recommended profile

**Related:** [handoff](handoff.md) · [active-agents](active-agents.md) · [command-palette](command-palette.md) · [settings](settings.md)

## What a profile is

A profile is a named preset for one runtime: display name, optional custom SF
Symbol icon, runtime-supported launch options, and a launch placement (New Tab
or New Split with a direction). Model, reasoning effort, execution mode, and
Dedicated Home appear only when that CLI has a verified mapping for the field;
Extra Arguments and launch-scoped environment variables remain available for
expert configuration. By default a profile is **argv-only**: launching it is
exactly like typing that CLI with those flags yourself — same login, skills,
and session history. The same runtime can have any number of profiles.

On first run Prowl seeds one bare profile per installed runtime. Seeds are
ordinary profiles: rename, edit, or delete them freely — deleted seeds never
respawn.

## Launching

- **Toolbar Agents capsule** — always opens a popover. With a detected agent it
  leads with Hand Off; a "Workflows" section follows when `PROWL_WORKFLOW_UI=1` and the worktree can
  see workflows (each row starts the workflow, its trailing `ellipsis.circle`
  menu offers "Run with Options…" and "Show Details in Settings…", and files that fail
  validation are listed dimmed with their reason; see
  [workflows](workflows.md)); launch rows follow under a
  "New agent in this worktree" section header, the current worktree's
  **Recommended** profile first. Each
  row shows the profile name with the runtime name trailing. Rows for runtimes
  that look unavailable are dimmed with a warning but stay clickable —
  availability signals can be wrong, so they never block a launch. "Manage
  Agent Profiles…" opens Settings → Agents → Profiles. When launch rows exist
  the capsule
  carries a trailing **quick-launch segment** (a `play.circle` split button):
  one click launches the Recommended profile directly, skipping the popover.
- **Command Palette** (`⌘P`) — "Launch Agent: <name>" rows dispatch the exact
  same action, and carry the same availability warning in their subtitle.
- **CLI** — `prowl profiles list` returns enabled and disabled Profiles with their
  runtime and shell-probe availability. Launch into a deterministic new tab or anchored
  split with `prowl create tab|pane … --profile <name|uuid>`; add `--prompt -` to read a
  kickoff prompt from stdin and `--background` to preserve the current selection/focus.
  Disabled Profiles cannot launch; availability warnings never block an attempt.

Every launch creates a **new** tab or split; Prowl never types the invocation into an
existing shell. Toolbar and Command Palette launches use the Profile's saved placement in
the current worktree and start interactively with no initial prompt; if a saved split cannot
be created, these interactive launchers fall back to a foreground tab. CLI launches override
placement from the `create tab|pane` command, remain strict about pane placement, and may
supply the kickoff prompt. A prompted
CLI launch is also an atomic dispatch: its create response includes a pending opaque receipt,
the launched child alone receives `PROWL_DISPATCH_ID`, and the effective prompt tells the
agent to finish with `prowl agents dispatch-complete --outcome … --summary …`; the required
summary is a control-free single line. Unprompted launches do not create a receipt. Failure to
launch or bind rolls back the new surface and cancels the unpublished dispatch; a new CLI also
rejects an old app response that omits the
required dispatch metadata.

The new pane records its profile identity at
creation: the Active Agents rows and the capsule show the profile's display
name (frozen at launch — later renames don't relabel live panes). The identity
lives exactly as long as the launched agent: once it exits, any agent started
manually in that pane shows its own name and runs with your default
environment and account.
Claude Code, Codex, GitHub Copilot, Droid, Qoder, Pi, Oh My Pi, and OpenCode Profile launches
automatically prepare launch-scoped native signal bridges. Prowl writes no hook configuration
to runtime homes or repositories. Claude merges an explicit final `--settings` JSON/file
source in memory while preserving unknown fields and existing hook arrays; Codex preserves an
effective user notifier through a private transparent dispatcher; Copilot, Pi, and Oh My Pi
load a read-only file shipped inside Prowl through an additive flag; Droid and Qoder receive a
merged settings object; OpenCode receives a launch-scoped `OPENCODE_CONFIG_CONTENT` whose
plugin list is appended to whatever the Profile or your shell already exports. Hook JSON,
channel tokens, socket paths, and notifier argv ride in child-only carriers rather than
terminal input, shell history, preview values, logs, or durable Profile state. A manual
runtime started later in the same pane inherits none of this coverage. See
[Agent detection](agent-detection.md#managed-native-completion-signals) for each runtime's
events and the cases that run unchanged.

Preparation is bounded and occurs before a prompted dispatch is issued. If Prowl cannot
safely merge settings or content, resolve a configuration or shell environment, preserve a
notifier, or find its bundled resource — or the runtime's own flags disable hooks
(`--setting-sources`, `--pure`) — the Profile still launches with its original argv and no
exact managed channel. Toolbar and
Command Palette show one non-blocking warning toast. CLI JSON adds one optional
`warnings: [{code: "managed_hook_degraded", runtime, message}]`; text output writes the
warning once to stderr. Receipt behavior is unchanged.

A Toolbar or Command Palette launch that fails before its surface exists (e.g.
home provisioning) shows a warning toast, and only a successful launch from
those UI surfaces updates the per-repo "last launched" memory behind the
Recommended resolution. CLI launches instead return a structured error and do
not update Recommended memory.

## Managing profiles

Open **Settings → Agents → Profiles** to see the ordered profile list. Click a
profile to push its editor; the native Back control returns to the list while the Settings
sidebar remains available. Adding a profile opens the same editor immediately.
Changing another Settings sidebar section leaves the editor and opens that
section's root.

The editor's **Icon** preview opens an SF Symbol picker. A custom symbol appears
where Prowl presents the launch preset: the Settings list, repository Default
Agent Profile picker, toolbar Agents popover, and Command Palette. Clearing it
restores the runtime's brand icon. Live panes and Active
Agents retain the icon of the process Prowl actually detects.

Changing a profile's **Agent** resets its Model, Reasoning Effort, Extra
Arguments, and execution mode to the new runtime defaults. Unsupported fields
disappear instead of carrying stale state across runtimes; add new values only
after choosing the destination agent.

**Recommended** resolves in three tiers: the repo's **Default Agent Profile**
(Repo Settings) → the last profile explicitly launched in this repo → the
first enabled profile in the Settings list order. Each tier only matches an
existing, enabled profile.

## Environment variables

The **Environment Variables** table (Advanced, below Extra Arguments) adds
per-profile environment overrides — e.g. `OPENAI_BASE_URL` + `OPENAI_API_KEY`
to get a "Codex but using DeepSeek" profile. The whole patch is
**launch-scoped**: it applies to the launched agent process (and its
subprocesses) only. The pane's shell keeps your normal environment, so after
the agent exits, a manual agent launch — or any other command — in that
pane runs with your own account and environment. Mechanically, the launch
command carries `env NAME="$PROWL_ENV_NAME" …` references while the values
ride in hidden `PROWL_ENV_*` surface variables, so no override value ever
appears in the typed command, shell history, or scrollback. Rules:

- Names must be valid POSIX names (`[A-Za-z_][A-Za-z0-9_]*`). An empty value
  legitimately sets the variable to the empty string.
- Reserved names are ignored at launch and flagged inline: anything starting
  with `PROWL_`, `HOME` (relocating it would move every runtime's default home
  past Prowl's provisioning and deletion safeguards), plus the account-home
  variables (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GEMINI_CLI_HOME`,
  `COPILOT_HOME`, `QWEN_HOME`, `PI_CODING_AGENT_DIR`, and `CLINE_DATA_DIR`) — a custom home must go
  through **Use Dedicated Home**, which always wins over a same-named row.
- Later duplicate names win (shell-export semantics).
- Values are stored in plaintext in `~/.prowl/global.onevcat.json` (kept
  owner-only, `0600`); the Launch Preview shows only the `$PROWL_ENV_*`
  references, never the values.
- Launch-scoped by design: manual launches, resumed sessions, and restored
  panes intentionally run with your default environment. Re-launch through
  the Agents menu to get the profile's environment again.

## Dedicated home (separate account)

For runtimes with a verified full-state relocation, toggling **Use Dedicated
Home** (Advanced) gives the profile its own runtime home under
`~/.prowl/agent-profiles/<uuid>/`. Prowl attaches it with the CLI's native
environment variable or managed path arguments, launch-scoped like overrides.
That relocates the runtime's *entire* home:
separate login and usage, but also separate skills, global instructions
(`CLAUDE.md` / `AGENTS.md`), and session history. The first launch is the
sign-in moment — the agent's own TUI walks through login and the credentials
land inside the profile home. Prowl never reads or copies them; use **Reveal
Profile Files** to manage skills and instruction files there yourself. After
the launched agent exits, a manually started agent in the same pane uses your
default home and account — re-enter the profile's account by launching from
the Agents menu again.

Removing any profile asks first. Pure presets have no file operations. A bound
profile offers **Remove Profile** to keep its folder on disk and **Remove and
Trash Files** to move the folder to the Trash (never `rm`).

## Advanced extra arguments

The **Extra Arguments** field appends literal argv tokens after the
preset-generated options (quotes group values with spaces; nothing is ever
shell-interpreted). A bound Profile's managed-home arguments follow Extra
Arguments so an accidental duplicate cannot redirect credentials outside the
UUID home; otherwise your flags remain last-wins. The editor stays honest
about what it can prove: recognized bypass flags (`--yolo`,
`--dangerously-skip-permissions`, …) show the red least-restricted warning even
when the picker says Standard; any other extra argument (including
`--sandbox`/`--ask-for-approval`/`-c` overrides) shows a neutral "effective
execution mode follows your extra arguments" note instead of claiming
Standard — the semantics belong to your command line. When the picker itself
requests Unrestricted, the warning deliberately remains conservative even if
later Extra Arguments may override the generated flags: Advanced arguments
are authoritative, and Prowl does not attempt to interpret every runtime's
full, evolving option and configuration surface.
The editor opens with a **Profile** section (name, agent, icon), followed by
**Launch Preview** — the deterministic base invocation, including the env prefix
for bound profiles. Execution-only managed-signal settings, tokens, socket paths, and
forwarding locators are prepared later and remain redacted from the preview — then a
**Details** section with the remaining launch options (model, reasoning
effort, execution mode, placement).

## Runtime capability matrix

All listed runtimes support a bare interactive Agent Profile launch. Pi and Oh
My Pi are independent runtime and detection families: each keeps its own
executable, icon, screen heuristics, home, and session identity.

| Runtime | Model | Reasoning | Execution mode | Dedicated Home |
| --- | --- | --- | --- | --- |
| Claude Code | Yes | Yes | Standard / Unrestricted | `CLAUDE_CONFIG_DIR` |
| Codex | Yes | Yes | Standard / Unrestricted | `CODEX_HOME` |
| Gemini CLI | Yes | No | Standard / Unrestricted | `GEMINI_CLI_HOME` |
| Cursor Agent | Yes | No | Standard / Unrestricted | No verified full-state relocation |
| Cline CLI | Yes | Yes | Standard / Unrestricted | Managed config, data, and hooks paths |
| OpenCode | Yes | Yes | Standard / Unrestricted | No; config override does not move auth/session data |
| GitHub Copilot | Yes | Yes | Standard / Unrestricted | `COPILOT_HOME` |
| Kimi Code | Yes | No | Standard / Unrestricted | No verified full-state relocation |
| Factory Droid | No | No | Runtime default only | No verified full-state relocation |
| Amp | No | Yes | Runtime default only | No verified full-state relocation |
| Qoder CLI | Yes | Yes | Standard / Unrestricted | `--config-dir` |
| Qwen Code | Yes | Yes | Standard / Unrestricted | `QWEN_HOME` |
| Grok Build | Yes | Yes | Standard / Unrestricted | No verified full-state relocation |
| Pi | Yes | Yes | Runtime default only | `PI_CODING_AGENT_DIR` |
| Oh My Pi | Yes | Yes | Standard / Unrestricted | `PI_CODING_AGENT_DIR` |

The execution-mode picker appears only when Prowl can render both choices
honestly. Cline maps Standard to `--auto-approve false` and Unrestricted to
`--auto-approve true`; Grok maps them to `--permission-mode default` and
`--permission-mode bypassPermissions --sandbox off`; Oh My Pi maps them to
`--approval-mode always-ask` and `--approval-mode yolo`. Managed policies,
hooks, and per-tool deny or prompt rules remain authoritative.

Factory Droid, Amp, and Pi deliberately have no picker. Droid exposes tiered
interactive autonomy and reserves its full bypass for headless `droid exec`.
Amp and Pi normally run without approval prompts, but neither offers a
launch-scoped pair of CLI flags that lets Prowl force both a guarded Standard
mode and the default least-restricted mode. Their own configuration remains in
control; Extra Arguments stay available for expert overrides.

Amp has one additional limitation: it supports bare interactive Profile launch
and `--execute` headless launch, but has no argv form that seeds a prompt and
then remains interactive. Toolbar/Command Palette and CLI launches without `--prompt`
still work; `create … --profile <amp-profile> --prompt -` fails without creating a pane.

## Where things live on disk

| What | Where |
|------|-------|
| Profiles + seeding flag | `~/.prowl/global.onevcat.json` |
| Per-repo default + launch memory | `~/.prowl/repo/<name>/prowl.onevcat.json` |
| Dedicated profile homes | `~/.prowl/agent-profiles/<uuid>/` |

## Gotchas for agents

- Session detection follows the relocated home while the launched bound agent
  is running (resume and handoff artifacts resolve against the profile's
  config root); once it exits, the pane's config root reverts with the
  identity. An agent you start manually with your own runtime-home override is
  still detected, but without session
  identity.
- Availability is judged in two tiers. Ground truth is a background
  login-shell probe (`command -v`, the same PATH resolution a launch uses):
  once it answers, "not found" warns "… is not on your shell's PATH" and
  "found" clears any warning. Until it answers, the fallback heuristic — the
  runtime's default home exists iff the CLI has
  ever run — warns "… may not be installed". One login shell batches all
  pending runtime lookups. A positive answer is cached for the session;
  negative answers are cached for five minutes before becoming eligible for
  another background probe, so installing a CLI is still detected without
  repeatedly loading shell startup files whenever the Agents popover opens.
  Both signals only dim rows, never disable them.
- Prowl provides no directory sharing between a bound home and the default
  one. Symlinking read-mostly directories (e.g. `skills/`) yourself works, but
  never link files the CLI rewrites (`settings.json`, `config.toml`,
  `auth.json`) — atomic rewrites replace the symlink and silently diverge.
