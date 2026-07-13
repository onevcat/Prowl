# 046 — Mobile Remote Control: Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-07-13 |
| **Primary PRs** | Pending |
| **Related** | #196, [013-prowl-cli](../013-prowl-cli/000-plan.md), `docs/components/cli.md` |

## Background

Issue #196 asks for mobile access to a running Prowl instance. The existing `prowl`
control plane is intentionally local-only: `supacode/CLIService/CLISocketServer.swift`
uses an owner-only Unix socket and verifies the peer UID. Its generic command router
also includes terminal input and destructive actions, and its responses contain local
paths and agent-session metadata. It must not be placed behind a network listener.

The issue does not define a mobile client, transport, or remote write capability. The
owner identified a proof of concept as the appropriate first increment.

## Goals

- Add an opt-in, loopback-only read-only bridge for a separately authenticated private
  tunnel or overlay.
- Require a high-entropy bearer credential stored outside `~/.prowl/settings.json`.
- Return a path-free agent projection and bounded viewport text through opaque IDs.
- Let Settings start and stop the listener immediately, with documented security bounds.

### Non-goals

- A native iOS client, Prowl-managed relay, public listener, TLS termination, push
  streaming, or automatic tunnel configuration.
- Re-exporting the CLI protocol or exposing `send`, `key`, `focus`, `open`, `tab`, or
  `pane` actions.
- Scrollback access, unbounded output, device-specific pairing, or per-device auditing.

## Design / Approach

1. Add a dedicated HTTP request router under `supacode/CLIService/`. It accepts only
   authenticated `GET` requests for an agent summary and limited current viewport text;
   it does not accept a `CommandEnvelope`.
2. Build remote DTOs directly from live app and terminal state in `supacode/App/supacodeApp.swift`.
   They omit paths, CWDs, transcript paths, and raw terminal identifiers. Reads use a
   short-lived opaque mapping plus line and UTF-8 byte caps.
3. Bind a small listener to `127.0.0.1` only. A Keychain-backed random bearer token is
   never written to the global settings model or emitted through `SupaLogger`.
4. Add a public `remoteControlEnabled` setting through the global model, Settings
   reducer, and Advanced settings view. An app-owned service coordinates lifecycle
   changes without subscribing to the single-subscriber terminal event stream.
5. Cover authentication, allowlisting, redaction, output limits, settings persistence,
   and start/stop behavior with tests, then document safe deployment.

## Alternatives & decisions

| Decision | Rejected alternative | Rationale |
| --- | --- | --- |
| Separate read-only protocol and DTOs | Forward the CLI socket or command router | The local trust model and payloads are unsafe at a network boundary. |
| Loopback listener plus user-managed private TLS tunnel | Bind LAN/public TCP directly | Prowl owns neither a relay nor certificate/identity infrastructure. |
| Keychain-backed rotating token | Persist it in `GlobalSettings` | Settings may be symlinked or copied into dotfiles and are not a secret store. |
| Request/response polling | Subscribe to terminal events | The terminal event stream currently permits one subscriber. |

## Amendments
None.
