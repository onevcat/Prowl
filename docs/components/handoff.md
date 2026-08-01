# Handoff — Agent To Agent

> How to hand a task off between coding agents inside a Prowl runnable target:
> a pure, archive-first transition over `.prowl/handoff/`, an inline
> agent-authored briefing (`prowl handoff to <agent> --brief -`), a headless
> background launch of the receiver, and in-app entry points (Agents capsule,
> Hand Off HUD, command palette) that ask the live agent to run that same CLI
> transition itself.

**Keywords:** handoff, hand off, briefing, codex, claude, switch agent, takeover, `.prowl/handoff`, current.md, prowl handoff, --brief, cross-agent, workspace

**Related:** [workspaces](workspaces.md) · [cli](cli.md) · [agent-detection](agent-detection.md) · [command-palette](command-palette.md)

## Why

Coding agents are independent processes; each keeps its own conversation
context. When you switch from one to another, the first agent's in-memory
context is **not** visible to the second. The only durable channel between them
is the filesystem. Handoff makes that channel a first-class, structured
artifact — and makes sure the artifact is **fresh** for every transition: the
receiver never reads a previous round's notes as if they were today's
contract.

Handoff is centred on [workspaces](workspaces.md) — one task, several repos, a
shared root — but works for any runnable target.

## The transition

Every handoff runs one pure sequence, no matter which entry point started it:

```text
collect briefing → archive outgoing state → install fresh current.md
(or remove the stale one) → regenerate context.md → launch receiver
(background tab) → log + notification
```

- The **archive comes first**: whatever the previous round left in
  `current.md`/`context.md` is snapshotted to
  `archive/<ts>-<from>-to-<to>.md` before anything is rewritten, so history
  always survives.
- `current.md` **exists iff a validated briefing produced it**. There is no
  template and no manual upkeep; when no briefing is available the file is
  removed and the receiver is pointed at `context.md` + `archive/` instead.
- `context.md` is derived at transition time from live git state and the
  pane's session identity — it is never "maintained" between handoffs.
- The launch is **headless**: the receiving agent starts in a background tab
  of the same worktree. Nothing switches your selected worktree, steals
  focus, or raises a window. A notification (`codex → claude · <worktree>`,
  click to jump) fires unless you are already watching that worktree — there,
  the appearing tab is the signal.

## The briefing: inline first

The briefing is always **agent-authored**; the difference between the paths is
only whether the author is present:

- **Inline (`--brief`) — the primary path.** The outgoing agent hands itself
  off as its final action and writes the briefing in the same breath:

  ```bash
  prowl handoff to codex --brief - <<'EOF'
  # Handoff
  ## Objective
  …
  ## Current State
  …
  ## What Has Been Done
  …
  ## Open Questions
  …
  ## Risks / Watch Out
  …
  ## Next Steps
  …
  ## Suggested Prompt For Next Agent
  …
  EOF
  ```

  The live agent holds working context that no recorded transcript can
  reproduce (on current models, transcripts persist reasoning as empty signed
  stubs), plus the *intent* of the handoff itself — which is exactly what
  "Suggested Prompt For Next Agent" needs. Inline costs no extra model call
  and no waiting.
- **Fork — the explicit fallback.** When the author is not on the command
  line (you are handing off a third pane, or rescuing a wedged agent), Prowl
  resumes the source's recorded session headlessly and asks it to reply with
  the briefing. The resume is side-effect-free by construction: Claude Code
  runs with `--fork-session`, Codex with `--ephemeral`, so the live session's
  recorded state is never touched; no permission flags are ever passed. One
  fork turn is bounded to **2 minutes**.
- **Context-only.** With `--no-brief` (or when no safe fork exists) the
  transition carries `context.md` and the archive chain only.

Validation is uniform: a briefing must contain at least `## Objective`,
`## Current State`, and `## Next Steps` (chat preamble and code fences are
stripped). An invalid inline brief errors with guidance and **zero side
effects**; an unusable fork reply degrades the transition to context-only
(`briefing=failed` in the log).

## The artifact

Everything lives under the target's `.prowl/handoff/` directory:

```text
<root>/.prowl/handoff/
  .gitignore            self-ignore all local handoff state
  current.md            the current validated briefing (absent when none)
  context.md            Prowl-generated repository and session state
  log.md                append-only handoff history
  archive/<ts>-<from>-to-<to>.md      outgoing snapshot of each transition
  archive/<ts>-replaced-current.md    briefing replaced by a checkpoint
  sessions/<ts>-<pane>.md             terminal excerpt per save
```

Prowl creates `.prowl/handoff/.gitignore` with `*`, so the entire directory is
self-ignoring when the target is a git repository or worktree.

`sessions/<ts>-<pane>.md` is a normalized excerpt from the outgoing pane. It
records the detected agent, session id, pane, source, confidence, and native
transcript path when one is available — the same pid-anchored session identity
exposed by `prowl agents`. Ambiguous sessions are omitted rather than guessed.

## The `prowl handoff` command

```bash
prowl handoff to <agent> [target] [--brief -|--no-brief] [--note "…"] [--no-launch]
prowl handoff to --agent-profile-id <uuid> \
  [--pane <id> | --tab <id> | --worktree <source>] \
  [--brief -|--no-brief] [--note "…"] [--no-launch]
prowl handoff save       [target] [--brief -|--no-brief] [--note "…"]
```

- **`to <agent>`** selects a Runtime Default receiver and preserves the
  existing portable source inheritance: an explicitly observed unrestricted
  mode can carry across the verified Claude Code/Codex adapters, while model
  identifiers stay within one runtime family. Interactive launch is verified
  for `claude` and `codex`; `--no-launch` still archives + saves and accepts
  every detected-agent token (`pi`, `claude`, `codex`, `gemini`,
  `cursor-agent`, `cline`, `opencode`, `copilot`, `kimi`, `droid`, `amp`,
  `qodercli`, `qwen`, `grok`).
- **`to --agent-profile-id <uuid>`** selects an enabled
  [Prowl Agent Profile](agent-profiles.md). The Profile is authoritative for
  runtime, model, effort, execution mode, Extra Arguments, environment,
  Dedicated Home/account, and pane identity; none of those values are
  inherited from the source. For example, a Codex native config profile stays
  ordinary Profile Extra Arguments: `-p work`. A Profile handoff always opens
  a new background tab in the source worktree, ignoring that Profile's manual
  **Open In** split/tab choice. `--no-launch` resolves and records the enabled
  Profile but does not prepare a launch, provision its home, create a pane, or
  update Last Launched Profile.
- **`save`** is the deferred-handoff checkpoint: install a fresh briefing and
  regenerate context, with no destination and no launch. Use it when you stop
  for the day and the successor doesn't exist yet. A checkpoint never removes
  an earlier briefing — with no receiver, the last valid one stays.

### Who is the source?

- An explicit selector (`--pane p3`, `--tab t2`, `--worktree <name>`, or the
  positional target) always wins. The positional source is available only in
  the runtime form; to override the calling pane in the Profile form, use an
  explicit selector flag.
- Otherwise the source is **the calling pane**: Prowl resolves the `prowl`
  process's ancestry to the pane whose shell spawned it. An agent running
  `prowl handoff to …` inside its pane is therefore handing off **itself** —
  no matter what you have focused.
- Run outside any Prowl pane with no selector, the command errors
  (`SOURCE_REQUIRED`). The focused pane is never guessed at.

Self-handoffs require `--brief` (or an explicit `--no-brief`): the author is
right there, so asking it to rerun with its own briefing is the cheapest
correct outcome — the error message contains a copy-pasteable heredoc. For
third-party sources the fork fallback applies automatically, and a failed
fork degrades to context-only rather than blocking a rescue.

The receiving agent's kickoff prompt adapts: with a briefing it starts from
`current.md`'s Next Steps; without one it orients from `context.md` and the
archive. For a Runtime Default receiver, when Prowl observed the outgoing
launch, an explicitly observed unrestricted execution mode carries over to the
**destination launch only** across the verified claude/codex adapters; model
identifiers stay within the same agent family. A Profile receiver instead uses
only its frozen Profile configuration. Full flag/payload reference:
[cli](cli.md#prowl-handoff).

## In the app: the Agents capsule and the Hand Off HUD

A capsule button left of the branch title identifies the selected pane's
detected agent. Clicking it opens a popover whose hand-off row explains the
action — "Pass this task to another agent in a new tab; <agent> writes its own
briefing first" — and opens a centered HUD. The popover is always available:
below the hand-off row it lists launchable
[agent profiles](agent-profiles.md) (Recommended first) and a
"Manage Agent Profiles…" entry, so the capsule doubles as the launcher even
when no agent is detected. The Command Palette (`⌘P`) offers
the same flow as a single **Hand Off…** row; so does right-clicking a row in
the [Active Agents panel](active-agents.md), which targets the row's own pane.

The HUD is a trigger and an observer for the same CLI transition:

1. **Choose** — enabled Agent Profiles appear first, with the current repo's
   Recommended Profile selected by default; remaining Profiles keep Settings
   order. Runtime Default Claude Code/Codex targets follow (the current agent
   stays listed as a fresh-session restart), then **Only save progress, don't
   hand off**. With no enabled Profiles, the original Runtime Default list is
   unchanged.
2. **Ask the live agent** — Prowl types a one-line request into the source
   pane asking the agent to run `prowl handoff … --brief -` itself, then
   waits. The agent writes its briefing in its own words and the transition
   completes through the CLI service; the HUD observes the completion and
   jumps you to the exact receiver pane. If launch fails after the artifacts
   were committed, the HUD says that progress was saved but the receiver was
   not launched. If the agent is busy, the request queues in its
   input — the HUD says so. While waiting the panel is **non-modal**: the
   keyboard stays with the terminal (the request may trigger permission
   prompts you need to approve), and clicking outside collapses the panel —
   the hand-off still completes headlessly and notifies.
3. **Fallbacks while waiting** — **Fork Briefing** (only for a resumable
   exact/high-confidence claude/codex session) collects the briefing from the
   recorded session instead; **Context Only** hands off without one;
   **Cancel** closes the panel (an already-injected request can't be unsent —
   if the agent still hands off, it completes headlessly and notifies).

Because the request is plain language, **any detected agent can be a
source** — the pane-injection path is not limited to claude/codex; only the
fork fallback is.

## Safety

- Handoff never commits, pushes, or runs destructive git — saving only
  **reads** git state (`status` / `diff --stat`).
- The fork resume is side-effect-free by construction: `--fork-session` /
  `--ephemeral`, never a `--dangerously-*` flag, regardless of how the source
  was launched. Unrestricted-mode inheritance applies only to the interactive
  destination launch.
- Archive-before-write is a global invariant: no rewrite of `current.md` can
  destroy the only copy of the previous round.
- `to` only **adds** a background tab; it never closes the outgoing agent's
  session, so you can still read or roll back from it.
- Keep secrets/tokens out of the briefing; `.prowl/handoff/` is self-ignoring
  and session excerpts belong in local state, not source control.
- Profile Extra Arguments, environment values, Dedicated Home paths, and
  credentials never enter the injected request, CLI payload, handoff
  artifacts, or transition log. Only Profile ID/name and resolved runtime are
  recorded.

## Gotchas

- Workspaces aggregate generated context across their child repositories. A
  regular repository or worktree covers just that repo; a plain folder omits
  git branch and diff details.
- The HUD's injected request lands in the agent's input queue; a busy agent
  answers it after its current step. Use the fork/context-only fallbacks if
  you cannot wait — or Cancel, and the handoff completes in the background
  when the agent gets to it.
- Launching uses the interactive receiving agent (so you can step in); don't
  use `--capture` against it — read its screen with `prowl read --wait-stable`.
