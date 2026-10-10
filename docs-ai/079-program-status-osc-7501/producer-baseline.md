# OSC 7501 producer baseline

Living document: what each producer actually sends when the terminal answers the support
query. Re-run the harness and update the table before enabling OSC-first for a new producer
version, and whenever a producer upgrade changes Prowl's detection. "Not observed" means the
scenario was run and no report arrived, not that the producer never sends one.

## Harness

```sh
# answer the probe, accept Claude's trust dialog (Down, Enter), send one prompt
scripts/program_status_probe.py --seconds 40 \
  --keys '3:\x1b[B;3.3:\r;7:reply with just the word ok\r' -- claude

# pi: prompt, then ctrl+d twice to exit
scripts/program_status_probe.py --seconds 32 \
  --keys '4:reply with just the word ok\r;24:\x04;25:\x04' -- pi
```

The harness spawns the program in a pty (120×40, `TERM=xterm-256color`, `CLAUDE*` variables
removed), echoes `OSC 7501 ; ?` with the producer's terminator, answers DA1 and the kitty
keyboard query, sends scripted keys, and prints each report with its offset in seconds.
Run it from a disposable directory: the prompts call the model and Claude's first run in a
new directory shows the trust dialog.

## Claude Code 2.1.296 (2026-10-10, macOS, default permission mode)

| Scenario | Reports (offset from launch) |
| --- | --- |
| Launch | query at 0.25–0.5 s together with DA1 and `CSI ? u`; nothing until the trust dialog is answered |
| Trust dialog accepted, TUI mounted | `state=idle:app=claude-code` |
| Prompt submitted | `state=working:app=claude-code` within 0.05 s of Enter |
| Tool running | `state=working:app=claude-code:msg=<base64>` (msg was the tool description, e.g. "Listing files in current directory with details") |
| Bash approval prompt | `state=blocked:app=claude-code:kind=permission:msg=<base64 "approve Bash: touch probe-touch.txt">` |
| Turn finished | `state=done:app=claude-code` |
| Exit (trust dialog declined, or quit) | `state=clear` |

Not observed: a report for the trust dialog itself; child records (`id=`) — no subagent
scenario was run; `question`/`auth` kinds. `ls -la` ran without an approval prompt (read-only
command), so a write command is needed to reproduce `blocked`.

## Pi 1.1.0 (2026-10-10, macOS, onevcat's settings, model gpt-6-astra)

| Scenario | Reports (offset from launch) |
| --- | --- |
| Launch | query at 0.4–0.5 s; `state=idle:app=pi` within 0.01 s of the echo, before the TUI finished drawing |
| Prompt submitted | `state=working:app=pi` within 0.05 s of Enter |
| Turn finished | `state=done:app=pi` |
| Escape during a turn | `state=idle:app=pi` ("Operation aborted"), not `error` |
| ctrl+d at the prompt | `state=clear`, then exit |
| `/model` selector open and dismissed | not observed (no report either way) |
| Bash tool (`touch`) | ran without a confirmation under these settings: `working` → `done`, no `blocked` |

Not observed: `blocked` of any kind, child records, `error`. Pi 1.0.2 (the previous local
version) sent no query.

## Replay rules

- A producer's row is evidence for that version only; re-run on upgrade before trusting a
  new state or kind.
- Timings are for ordering (query before DA1, idle after mount), not latency guarantees.
- Keep `msg` out of durable logs by default; it is untrusted program text.
