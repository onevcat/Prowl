# 084.015 — Typed launch environment (A7)

## Context

Slice A7 of [000-plan.md](000-plan.md) prepares docs-ai 082 L1f, remote Profile
launches. A Profile launch types `env [-u CARRIER…] NAME=… … <invocation>` into a local
shell (docs-ai 053/006).

`AgentProfileLaunchPlan.commandEnvironmentTokens` held those assignments as finished
shell strings, such as `CODEX_HOME='/base/…'` and `OPENAI_API_KEY="$PROWL_ENV_OPENAI_API_KEY"`.
A remote launcher cannot reinterpret a finished string: it needs to know which values are
literal and which ride in a carrier variable. A carrier variable is a surface environment
variable that holds the value, so that the typed command names only the variable.

A7 can run in parallel with the A stack, so this PR is based on `main`.

## Change

- `AgentLaunchEnvironmentAssignment` has two cases:
  - `.literal(name:value:)`: a value that is typed into the command. It is used only for
    values that are not secret, such as the UUID-derived dedicated home.
  - `.carrier(name:carrier:)`: a value that rides in a surface carrier variable.
  - `token` renders the local shell form exactly as before:
    - a literal renders as `NAME='value'`, with `AgentInvocation.shellQuote`;
    - a carrier renders as `NAME="$CARRIER"`.
- `AgentProfileLaunchPlan.commandEnvironment: [AgentLaunchEnvironmentAssignment]` stores
  the assignments. `commandEnvironmentTokens` is now computed from it, so
  `terminalInput` and the launch preview stay byte-identical.
- These producers now build typed assignments:
  - the planner: dedicated home → literal; dispatch ID and profile overrides → carriers;
  - `applyingManagedHook`: hook token, socket, hook environment values and the Codex
    forwarding record → carriers;
  - `attachingWorkflow` and `attachingDispatch`: carriers.

There are no other changes. The carrier `-u` list, the surface environment and the order
of the assignments are the same.

## For L1f

A remote launcher renders the same `commandEnvironment` its own way. For example, it can
send carrier values over the command lane's stdin instead of the surface environment, and
type only literals. L1f must keep the secrecy rule: a carrier value never appears in the
typed command, shell history or scrollback.

Two points to settle in L1f:

- **Names.** `token` writes `name` and `carrier` without quoting. Today every name is a
  constant or an override name that `AgentProfileEnvironmentPolicy` already validated.
  If a remote launcher accepts names from another source, it needs its own identifier
  check.
- **The `-u` list.** `terminalInput` unsets the prompt, hook, dispatch and workflow
  carriers in the child, but not the profile override carriers (`PROWL_ENV_<NAME>`). The
  child therefore sees an override value under both its real name and its carrier name.
  A7 keeps this behaviour unchanged. The typed assignments make it a one-place change:
  derive the `-u` list from the `.carrier` cases. That would also replace the
  hand-written carrier list in `terminalInput`. It is a behaviour change for local
  launches, so it is left for onevcat to decide.

## Tests

- `AgentLaunchEnvironmentAssignmentTests`:
  - token rendering, including a value with a single quote;
  - a planned plan with an attached dispatch (the production path) keeps the meaning of
    each assignment: home literal, override and dispatch carriers;
  - its tokens equal the literal strings the old code produced, and the override value
    stays out of `terminalInput`.
- The existing Profile, hook rendering and terminal suites build plans with
  `commandEnvironment:`. Their expected command lines are unchanged. One fixture used a
  hand-written unquoted `CODEX_HOME=/tmp/home` token. As a typed literal it renders quoted,
  like every planner-built home.
