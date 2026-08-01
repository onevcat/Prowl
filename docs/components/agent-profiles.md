# Agent Profiles

> Named launch presets for the verified agents (Claude Code, Codex): one click
> in the toolbar **Agents** menu or the Command Palette starts a fresh agent in
> the current worktree with your model, effort, mode, and — optionally — a
> dedicated account.

**Keywords:** agent profile, preset, launch agent, agents menu, dedicated home, account, CLAUDE_CONFIG_DIR, CODEX_HOME, recommended profile

**Related:** [handoff](handoff.md) · [active-agents](active-agents.md) · [command-palette](command-palette.md) · [settings](settings.md)

## What a profile is

A profile is a named preset for one runtime: display name, optional custom SF
Symbol icon, optional model and reasoning effort (both accept free text with
per-runtime suggestions), execution mode (Standard / Unrestricted), and a
launch placement (New Tab or New Split with a direction). By default a profile
is **argv-only**: launching it is exactly like typing `claude`/`codex` with
those flags yourself — same login,
same skills, same session history. The same runtime can have any number of
profiles.

On first run Prowl seeds one bare profile per installed runtime. Seeds are
ordinary profiles: rename, edit, or delete them freely — deleted seeds never
respawn.

## Launching

- **Toolbar Agents capsule** — always opens a popover. With a detected agent it
  leads with Hand Off; launch rows follow under a "New agent in this worktree"
  section header, the current worktree's **Recommended** profile first. Each
  row shows the profile name with the runtime name trailing. Rows for runtimes
  that look unavailable are dimmed with a warning but stay clickable —
  availability signals can be wrong, so they never block a launch. "Manage
  Agent Profiles…" opens Settings → Agents. When launch rows exist the capsule
  carries a trailing **quick-launch segment** (a `play.circle` split button):
  one click launches the Recommended profile directly, skipping the popover.
- **Command Palette** (`⌘P`) — "Launch Agent: <name>" rows dispatch the exact
  same action, and carry the same availability warning in their subtitle.
- **Hand Off HUD** — enabled Profiles appear before Runtime Default receivers;
  the repo's Recommended Profile is first and preselected, then the remaining
  Profiles keep Settings order. A handoff uses the Profile's full launch
  configuration with a takeover prompt, but always opens a new background tab
  rooted at the source worktree — it deliberately ignores the Profile's normal
  **Open In** split/tab placement. While the HUD is still waiting, it focuses
  the exact receiver pane after success.

A launch creates a **new** tab (or split, per placement) in the current
worktree, running the agent interactively with no initial prompt. Prowl never
types into an existing shell. The new pane records its profile identity at
creation: the Active Agents rows and the capsule show the profile's display
name (frozen at launch — later renames don't relabel live panes). The identity
lives exactly as long as the launched agent: once it exits, any agent started
manually in that pane shows its own name and runs with your default
environment and account.
A launch that fails before its surface exists (e.g. home provisioning) shows a
warning toast, and only a successful launch updates the per-repo "last
launched" memory behind the Recommended resolution.

## Managing profiles

Open **Settings → Agents** to see the ordered profile list. Click a profile to
push its editor; the native Back control returns to the list while the Settings
sidebar remains available. Adding a profile opens the same editor immediately.
Changing another Settings sidebar section leaves the editor and opens that
section's root.

To create a Codex Profile backed by a native Codex config profile, choose
**Add Profile → Codex**, give it a Prowl display name, and put `-p work` (or
your native profile name) in **Extra Arguments**. There is no separate
Codex-profile field: this keeps all argv ordering and quoting in the Codex
runtime adapter. You can then choose the Prowl Profile by name from Hand Off;
the advanced direct CLI form is
`prowl handoff to --agent-profile-id <uuid> --brief -`.

The editor's **Icon** preview opens an SF Symbol picker. A custom symbol appears
where Prowl presents the launch preset: the Settings list, repository Default
Agent Profile picker, toolbar Agents popover, and Command Palette. Clearing it
restores the runtime's Claude Code / Codex brand icon. Live panes and Active
Agents retain the icon of the process Prowl actually detects.

Changing a profile's **Agent** resets its Model, Reasoning Effort, Extra
Arguments, and confirmed Unrestricted mode to the new runtime defaults. Those
values are runtime-specific; add new values after choosing the destination
agent.

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
the agent exits, a manual `codex` / `claude` — or any other command — in that
pane runs with your own account and environment. Mechanically, the launch
command carries `env NAME="$PROWL_ENV_NAME" …` references while the values
ride in hidden `PROWL_ENV_*` surface variables, so no override value ever
appears in the typed command, shell history, or scrollback. Rules:

- Names must be valid POSIX names (`[A-Za-z_][A-Za-z0-9_]*`). An empty value
  legitimately sets the variable to the empty string.
- Reserved names are ignored at launch and flagged inline: anything starting
  with `PROWL_`, `HOME` (relocating it would move every runtime's default home
  past Prowl's provisioning and deletion safeguards), plus the account-home
  variables (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) — a custom home must go
  through **Use Dedicated Home**, which always wins over a same-named row.
- Later duplicate names win (shell-export semantics).
- Values are stored in plaintext in `~/.prowl/global.onevcat.json` (kept
  owner-only, `0600`); the Launch Preview shows only the `$PROWL_ENV_*`
  references, never the values.
- Launch-scoped by design: manual launches, resumed sessions, and restored
  panes intentionally run with your default environment. Re-launch through
  the Agents menu to get the profile's environment again.

Profile handoff uses this same launch path. The injected request, handoff JSON,
artifacts, and log carry only Profile identity/runtime — never override values,
Extra Arguments, home paths, or credentials.

## Dedicated home (separate account)

Toggling **Use Dedicated Home** (Advanced) gives the profile its own runtime
home under `~/.prowl/agent-profiles/<uuid>/`, attached to the launched agent
via a `CLAUDE_CONFIG_DIR` / `CODEX_HOME` assignment on the launch command
(launch-scoped, like overrides). That relocates the runtime's *entire* home:
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
shell-interpreted). Your flags are respected as-is. The editor stays honest
about what it can prove: recognized bypass flags (`--yolo`,
`--dangerously-skip-permissions`, …) show the red unrestricted warning even
when the picker says Standard; any other extra argument (including
`--sandbox`/`--ask-for-approval`/`-c` overrides) shows a neutral "effective
execution mode follows your extra arguments" note instead of claiming
Standard — the semantics belong to your command line.
This is also where a Codex native config profile belongs: `-p work` is passed
unchanged before an optional handoff takeover prompt.
The editor opens with a **Profile** section (name, agent, icon), followed by
**Launch Preview** — the exact rendered invocation, including the env prefix
for bound profiles, using the same rendering as the real launch — then a
**Details** section with the remaining launch options (model, reasoning
effort, execution mode, placement).

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
  identity. An agent you start manually with your own
  `CLAUDE_CONFIG_DIR`/`CODEX_HOME` is still detected, but without session
  identity.
- Availability is judged in two tiers. Ground truth is a background
  login-shell probe (`command -v`, the same PATH resolution a launch uses):
  once it answers, "not found" warns "… is not on your shell's PATH" and
  "found" clears any warning. Until it answers, the fallback heuristic — the
  runtime's default home (`~/.claude` / `~/.codex`) exists iff the CLI has
  ever run — warns "… may not be installed". A positive probe is cached for
  the session; negatives re-probe each time the Agents popover opens, so
  installing a CLI mid-session clears its warning without a relaunch. Both
  signals only dim rows, never disable them.
- Prowl provides no directory sharing between a bound home and the default
  one. Symlinking read-mostly directories (e.g. `skills/`) yourself works, but
  never link files the CLI rewrites (`settings.json`, `config.toml`,
  `auth.json`) — atomic rewrites replace the symlink and silently diverge.
