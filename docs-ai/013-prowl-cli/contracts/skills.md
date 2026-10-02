# `prowl skills` Contract

## Status

Current version: `prowl.cli.skills.v1`.

`skills` manages the agent skills bundled inside the Prowl app: it links them into agent skill
folders so every runtime reads the version that matches the installed app. The whole command
group is **local-only**: it never opens the CLI socket, never launches or contacts a running
app, and works with Prowl closed. Every response uses `command: "skills"` and one closed
`data` object discriminated by `action`.

## Input

```bash
prowl skills list [--json]
prowl skills install [<skill>...] [--target <id>]... [--scope user|project] [--path <dir>] [--json]
prowl skills uninstall [<skill>...] [--target <id>]... [--scope user|project] [--path <dir>] [--json]
prowl skills path <skill> [--json]
```

### Bundle resolution

- `PROWL_SKILLS_DIR`, when set, is a skills root (`<dir>/<id>/SKILL.md`) and wins. A present but
  invalid value fails with `BUNDLE_NOT_FOUND`; it never falls back to the app bundle.
- Otherwise the CLI resolves its own executable — following symlinks such as
  `/usr/local/bin/prowl` — to `Prowl.app/Contents/Resources/prowl-cli/prowl` and reads the
  sibling `Contents/Resources/skills/`. A CLI that is not inside an app bundle fails with
  `BUNDLE_NOT_FOUND`; a skill with malformed frontmatter fails with `INVALID_SKILL_FRONTMATTER`.
- Skill ids are bundled directory names, enumerated in stable id order. `audience` is `user`
  (installable) or `workflow` (materialized by workflow runs, never installed).

### Targets

| id | User directory | Project directory | Read by |
| --- | --- | --- | --- |
| `claude` | `~/.claude/skills` | `<root>/.claude/skills` | Claude Code |
| `codex` | `~/.codex/skills` | `<root>/.codex/skills` | Codex |
| `agents` | `~/.agents/skills` | `<root>/.agents/skills` | Codex, Gemini CLI, Cursor Agent, OpenCode, Copilot CLI, Kimi CLI, Droid, Amp, Qoder CLI, Pi, Oh My Pi, Grok Build |

A target is **detected** when the parent of its skills directory (`~/.claude`, `~/.codex`,
`~/.agents`, or the same names under a project root) exists as a directory. `--target` is
repeatable and accepts only the ids above; any other id fails with `TARGET_NOT_FOUND` before
any change. An explicit `--target` selects exactly those targets and `install` creates their
skills directory when it is missing, detected or not. `uninstall` never creates directories.

### Scope and roots

- `--scope` defaults to `user`. The user root is `$HOME` (an explicit `HOME` override is
  honored so verification can use a temporary home).
- `--scope project` acts on a repository. The root is the nearest ancestor (including the
  start itself) that contains a `.git` entry — a directory or, for a worktree, a file — of
  `--path <dir>` when given, otherwise of the current directory. `--path` requires
  `--scope project` (`INVALID_ARGUMENT`); a missing path is `PATH_NOT_FOUND`, a non-directory
  is `PATH_NOT_DIRECTORY`, and a start point outside any Git repository is `PATH_NOT_FOUND`.
  Prowl never reads or edits Git state.
- Project-scope links stay inside the repository. If a target's parent directory
  (`<root>/.codex`) or skills directory (`<root>/.codex/skills`) exists and resolves outside
  the canonical root — for example a committed symlink to a shared folder — every command that
  would use it fails with `INSTALL_CONFLICT` before any change. User scope deliberately follows
  such symlinks because synced `~/.claude/skills`-style setups are supported.
- `list` reports user scope only.

### Selection and defaults

- Skills: with no ids, `install` and `uninstall` act on every `user`-audience bundled skill.
  Explicit ids must be bundled (`SKILL_NOT_FOUND`). Naming a `workflow`-audience skill in
  `install` fails with `SKILL_NOT_INSTALLABLE` before any change; `uninstall` and `path` accept
  any bundled id.
- Targets: with no `--target`, `install` acts on every detected target and fails with
  `TARGET_NOT_FOUND` when none is detected; `uninstall` acts on every detected target and
  succeeds with an empty `results` array when none is detected.
- Results are ordered skills (bundle order) × targets (table order). Repeated ids are
  collapsed; input order does not affect output order.

### Link semantics

- One absolute directory symlink per skill × target: `<skills dir>/<skill id>` → the bundled
  skill directory. The target's skills directory is created when missing.
- An existing symlink is replaced whether it is live or dangling, so `install` doubles as the
  repair for `broken`. A real file or directory is never replaced or removed: every selected
  slot is checked first and one conflicting slot fails the whole command with
  `INSTALL_CONFLICT` and no change.
- `uninstall` removes only symlinks, dangling ones included, regardless of where they point.
  A `not_installed` slot is reported unchanged.
- Each slot is re-read immediately before it is acted on. Targets whose skills directories
  alias the same folder (for example `~/.claude/skills` and `~/.codex/skills` both symlinked to
  one synced directory) therefore share one link: the first pair installs or removes it and the
  later pair reports `before == after` (`installed` / `not_installed`) instead of failing or
  relinking. `before` in each result is that per-slot reading, not the pre-command listing.
- An unexpected filesystem failure after the conflict check fails with `SKILLS_FAILED`; slots
  processed before the failure keep their new state, so re-run the command after fixing the
  cause.

### Status values

| `status` | Meaning |
| --- | --- |
| `not_installed` | Nothing occupies the slot. |
| `installed` | A symlink that resolves to this app's bundled skill directory. |
| `installed_different_source` | A symlink to another live location (for example a Debug build) — `destination` names it — or a real file/directory (`destination` absent). |
| `broken` | A dangling symlink; `destination` names where the app used to be. `install` repairs it. |

`destination` is the link target resolved against the link's directory. The schema ties it to
the status: it is required for `broken`, optional for `installed_different_source` (present
for a foreign symlink, absent for a real file or directory, so its absence identifies a
non-symlink occupant), and forbidden for `installed` and `not_installed`.

## Success: `list`

```json
{
  "ok": true,
  "command": "skills",
  "schema_version": "prowl.cli.skills.v1",
  "data": {
    "action": "list",
    "skills": [
      {
        "id": "prowl-cli",
        "name": "prowl-cli",
        "description": "Use the Prowl CLI (`prowl`) to inspect or control a running Prowl GUI app…",
        "audience": "user",
        "path": "/Applications/Prowl.app/Contents/Resources/skills/prowl-cli",
        "targets": [
          { "id": "claude", "detected": true, "path": "/Users/me/.claude/skills/prowl-cli", "status": "installed" },
          { "id": "codex", "detected": true, "path": "/Users/me/.codex/skills/prowl-cli", "status": "broken", "destination": "/Volumes/Old/Prowl.app/Contents/Resources/skills/prowl-cli" },
          { "id": "agents", "detected": false, "path": "/Users/me/.agents/skills/prowl-cli", "status": "not_installed" }
        ]
      }
    ]
  }
}
```

`path` is the canonical bundled directory; each target `path` is the link slot for that
skill. `workflow`-audience skills are listed with their status so a manual link is visible,
but they are never selected for installation.

## Success: `install` and `uninstall`

```json
{
  "ok": true,
  "command": "skills",
  "schema_version": "prowl.cli.skills.v1",
  "data": {
    "action": "install",
    "scope": "project",
    "root": "/Projects/App",
    "results": [
      {
        "skill": "prowl-cli",
        "target": "claude",
        "path": "/Projects/App/.claude/skills/prowl-cli",
        "before": "broken",
        "after": "installed"
      }
    ],
    "note": "Project-scope skill links are absolute paths specific to this Mac. Prowl never edits Git state; exclude them yourself (for example in .git/info/exclude) if they should stay out of version control."
  }
}
```

`root` is the scope root (`$HOME` for `user`, the project root for `project`). `before` and
`after` are the slot status before and after the change; an `uninstall` result ends in
`not_installed`. `note` is present only for project scope, exactly once per response.

## Success: `path`

```json
{
  "ok": true,
  "command": "skills",
  "schema_version": "prowl.cli.skills.v1",
  "data": {
    "action": "path",
    "skill": {
      "id": "reviewer",
      "name": "Reviewer",
      "audience": "workflow",
      "path": "/Applications/Prowl.app/Contents/Resources/skills/reviewer"
    }
  }
}
```

## Text output

- `list` prints one block per skill (id, name, audience tag) with one line per target:
  status (`installed`, `not installed`, `linked elsewhere`, `real file or directory`,
  `broken link`), link slot, `→ <destination>` for a foreign or dangling link, and
  `(target not detected)` when applicable.
- `install` / `uninstall` print one line per result: `installed`, `repaired`, `replaced`,
  `unchanged`, `removed`, or `not installed`, followed by `skill → target` and the slot path.
- `path` prints exactly the bundled directory followed by a newline, for `$(…)` use.
- The project-scope note is written once to stderr, prefixed `note:`, in text mode only. JSON
  mode keeps it in `data.note` and writes nothing to stderr, so stdout stays one envelope.
- Errors follow the common text form `error [CODE]: message` on stderr with empty stdout.

## Errors

`SKILL_NOT_FOUND`, `SKILL_NOT_INSTALLABLE`, `TARGET_NOT_FOUND`, `INSTALL_CONFLICT`,
`BUNDLE_NOT_FOUND`, `INVALID_SKILL_FRONTMATTER`, `INVALID_ARGUMENT`, `PATH_NOT_FOUND`,
`PATH_NOT_DIRECTORY`, and `SKILLS_FAILED` use the common error envelope with
`schema_version: "prowl.cli.skills.v1"`. Because the command never uses the socket,
`APP_NOT_RUNNING`, `SOCKET_PERMISSION_DENIED`, and `TRANSPORT_FAILED` cannot occur. See
[`cli-output-schema.json`](../../../CLI/Sources/ProwlCLIContracts/Resources/cli-output-schema.json).
