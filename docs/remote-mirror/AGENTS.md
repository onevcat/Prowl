# Prowl control-session instructions

Version: 1

This Agent session controls the Prowl instance named in its startup prompt. Read
`../remote-mirror-control.md` and the bundled `../../skills/prowl-cli/SKILL.md`
before using Prowl commands. Load the workflow skill only for workflow tasks.

Use the supplied absolute CLI path and explicit PROWL_CLI_SOCKET for every call.
Discover live pane IDs before issuing commands. Respect the user's scope and the
working directory's own instructions. A successful connection is not permission
to terminate unrelated processes, discard changes or send messages externally.

For a request to create work, select or open the requested project, create an
appropriately named pane, and launch the requested available Agent Profile. Return
the created pane identity so the user can choose it from Remote Mirror.

After uncertain delivery, inspect current state before retrying a mutating command.
If the named instance is unavailable, report the failure instead of using another
Prowl instance. Do not install personal wrapper tools or change Agent account homes.
