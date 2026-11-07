# Prowl CLI Input Contract

This document owns argv/stdin grammar. Shared target semantics live in
[targeting.md](targeting.md); JSON response contracts live in the command documents
and the executable [schema bundle](schema.md).

## Root grammar

```text
prowl [path]
prowl open [path]
prowl list | agents [read|signal|dispatch|dispatch-complete|dispatch-abandon|wait] | profiles | skills | focus | canvas | read | send | key | handoff | create | close
```

Bare path forms (`/`, `./`, `../`, `~/`, `file://`, `.`, `..`) enter `open`.
`--` stops option parsing. `--json` and `--no-color` are leaf-command output
options; JSON stdout always contains exactly one response envelope when parsing
succeeds.

## Shared target rules

- Generic target positions use `GenericTarget` from [targeting.md](targeting.md).
  Prefixed `pN`/`tN` handles work in `--target` and positional auto-targets.
- Typed selectors are mutually exclusive. A positional target plus selector flag is
  `INVALID_ARGUMENT`; no selector silently overrides another.
- `send` and `key` retain count-sensitive positional grammar:

| Command | 0 args | 1 arg | 2 args |
| --- | --- | --- | --- |
| `send` | stdin → focused pane | text → focused pane | target + text |
| `key` | invalid | token → focused pane | target + token |

`send p12` remains text to the focused pane. Use `send p12 'text'`, or stdin with
`--target p12`, for a target-first send.

## Lifecycle grammar

```bash
prowl create tab <worktree> [--path <directory>] [--profile <name|uuid> [--prompt -] [--background]]
prowl create tab --worktree <worktree> [--path <directory>] [--profile <name|uuid> [--prompt -] [--background]]
prowl create pane <pN|pane-uuid> --direction <right|left|up|down> [--profile <name|uuid> [--prompt -] [--background]]
prowl create pane --pane <pN|pane-uuid> --direction <right|left|up|down> [--profile <name|uuid> [--prompt -] [--background]]
prowl profiles list
prowl close <pN|tN|uuid> [--force]
prowl close --pane <uuid|pN|N> [--force]
prowl close --tab <uuid|tN|N> [--force]
```

`create tab` requires a worktree-only target. `create pane` requires a pane-only
anchor and explicit direction; it rejects `--target`, `--worktree`, `--tab`, bare
numbers, and focus fallback. `--prompt` accepts only `-`, reads non-empty UTF-8 piped
stdin up to 256 KiB, rejects an interactive terminal and NUL bytes, and requires `--profile`;
`--background` also requires `--profile`. `profiles list`
is a read-only global snapshot and accepts no target. `close` requires a pane-or-tab-only target and rejects
`--target`, `--worktree`, bare-number positions, and focus fallback. See
[create.md](create.md) and [close.md](close.md).

`tab create`, `tab close`, and `pane close` remain deprecated aliases for one
shipped release. They keep their legacy parser/transport behavior while emitting a
stderr warning; new automation must use the lifecycle grammar above.

## Local skills grammar

```bash
prowl skills list
prowl skills install [<skill>...] [--target <claude|codex|agents>]... [--scope user|project] [--path <dir>]
prowl skills uninstall [<skill>...] [--target <claude|codex|agents>]... [--scope user|project] [--path <dir>]
prowl skills path <skill>
```

`skills` is local-only: it resolves the bundle beside the executable (or `PROWL_SKILLS_DIR`)
and never opens the socket. `--target` is repeatable; `--path` requires `--scope project`
(`INVALID_ARGUMENT`); `path` requires exactly one skill id. See [skills.md](skills.md).

## Agent signal grammar

```bash
prowl agents signal <turn-ended|needs-input|session-start|session-end|progress>
                    [--progress <0...100>] [--session <id>]
                    [--origin <claimed-origin>] [--detail <text>]
```

`--progress` is valid only with `progress`; omitting it means indeterminate progress.
Session/origin are at most 256 UTF-8 bytes and detail is at most 32768. All are non-empty
and control-free when present. Parser and handler enforce the same shared validation.
See [agents-signal.md](agents-signal.md).

## Agent dispatch grammar

```bash
prowl agents dispatch <pN|pane-uuid> --prompt - [--on-draft <refuse|replace>]
prowl agents dispatch-complete --outcome <succeeded|failed> --summary <text>
prowl agents dispatch-abandon --dispatch <id> --reason <text>
prowl agents wait --dispatch <id> [--timeout <1...600>] [--include-screen <1...200>]
prowl agents wait <pN|pane-uuid> --until <idle|blocked|changed|exit> [--timeout <1...600>]
                  [--min-confidence <auto|exact|high|heuristic>] [--include-screen <1...200>]
```

`agents dispatch` requires a pane-only target and `--prompt -`: the prompt is piped UTF-8
stdin up to 256 KiB, CRLF-normalized, trailing newlines dropped, non-empty, and free of
control characters other than newline and tab. `--on-draft` defaults to `refuse`; only
`replace` is sent on the wire (`on_draft`). `dispatch-complete` takes no id; it forwards
a launch-scoped `PROWL_DISPATCH_ID` only when present. See [agents-wait.md](agents-wait.md).

## Canvas grammar

```text
prowl canvas show | hide | status
prowl canvas layout <arrange|organize|tile> [--show]
prowl canvas fit [--show]
```

`layout` takes exactly one positional layout name. `--show` is accepted only by `layout` and
`fit`. See [canvas.md](canvas.md).

## Command-specific exceptions

- `agents read <pN|pane-uuid>` is a pane-only semantic snapshot, no selectors or
  focus fallback.
- `agents dispatch <pN|pane-uuid>` is pane-only as well; it never falls back to focus.
- `agents signal` accepts no selector. Its source is the caller pane resolved from the
  socket peer process ancestry, never UI focus or `PROWL_PANE_ID`.
- `handoff` defaults to the calling pane, not UI focus.
- `list`, `agents`, and `profiles list` are global discovery commands with no target selector.
- `canvas` accepts no target selector: Canvas shows every open tab.
- `skills` accepts no target selector and never contacts the app; it acts on the local
  filesystem only.
- `open` consumes a path rather than a target.

## Transport request model

The CLI sends one typed `CommandEnvelope` over the local socket. Command spelling is
owned by `ProwlCLI` ArgumentParser declarations; target state resolution remains
app-side. Parser and handler both enforce destructive lifecycle constraints so a
malformed direct socket request cannot gain a focus fallback.
