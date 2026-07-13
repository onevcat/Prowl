# 046 — Mobile Remote Control: Action Log

## Timeline
| Date | Change | Ref |
| --- | --- | --- |
| 2026-07-13 | Added the read-only loopback bridge, Keychain credential store, opt-in Settings lifecycle, and regression tests. | `3a03bcf2` |
| 2026-07-13 | Added the agent-facing deployment and safety manual, then updated the docs sync baseline. | Pending commit |

## Outcome & current state (as of 2026-07-13)

- `supacode/CLIService/RemoteControlRouter.swift` accepts authenticated `GET` requests
  for active-agent summaries and bounded viewport reads only. It uses opaque IDs and
  returns no local paths, CWDs, or agent-session files.
- `supacode/CLIService/RemoteControlServer.swift` binds only `127.0.0.1:39466`;
  `RemoteControlAccessTokenStore.swift` holds a 32-byte rotating bearer token in the
  macOS Keychain.
- `supacode/App/supacodeApp.swift`, `RemoteControlClient.swift`, and the Settings
  feature start and stop the bridge immediately through `remoteControlEnabled`.
- `docs/components/remote-control.md` documents the private-tunnel requirement,
  endpoint limits, token rotation, and explicit write-operation exclusions.

## Deviations from plan

The proof of concept limits reads to the current viewport rather than scrollback, a
stricter safety boundary than planned.

## Open questions

The first increment has no native mobile client, managed relay, device-specific pairing,
or push transport. Those require a separately specified security and delivery model.
