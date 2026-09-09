# AI control console

The optional Remote Mirror control console is a named Agent terminal owned by this
Prowl app. It can inspect panes, open workspaces and create Agent sessions using the
bundled Prowl CLI. It does not require any personal wrapper or VKChannel tooling.

Read `remote-mirror/AGENTS.md` and the bundled `../skills/prowl-cli/SKILL.md` first. For workflow requests also
read `../skills/prowl-workflow/SKILL.md`. Resolve these paths relative to this file.
Use `--help` to confirm command arguments and `--json` for structured results.

The startup prompt supplies the absolute CLI path and `PROWL_CLI_SOCKET` for this
app instance. Keep that prefix on every invocation, including subprocesses. Never
silently switch to the default socket if the instance stops responding.

Inspect existing panes before acting. Refer to returned IDs rather than guessing
names. Create a new pane only when the user requests work that requires one; leave
existing programs running. Report command failures and uncertain delivery without
replaying operations that may already have been performed.

The selected working directory is the Agent's workspace. Preserve its existing
AGENTS.md and CLAUDE.md. This bundled guide supplements those instructions; do not
overwrite them, change account directories, or install personal tools.

Stopping Remote Mirror sharing does not terminate this Agent. Closing the Prowl
app ends its lifetime; this is not an independent background service.
