# Remote Control (Experimental)

> A deliberately limited, read-only bridge for checking active Prowl agents from a
> companion mobile client. It is not a remote terminal or a replacement for the
> local `prowl` CLI.

**Keywords:** remote control, mobile, bridge, bearer token, loopback, private tunnel, agent status, viewport

**Related:** [active-agents](active-agents.md) · [settings](settings.md) · [cli](cli.md)

## Enable and pair

Open **Settings → Advanced → Remote Control (Experimental)** and enable the
read-only bridge. It listens only at `127.0.0.1:39466`; it is never reachable from
the LAN or public internet by itself.

Copy the access token from the same section into a trusted companion client. The
token is stored in the macOS Keychain, not in `~/.prowl/settings.json`. **Rotate and
Copy Access Token** immediately revokes clients using the old token.

To reach the bridge from a phone, provide your own authenticated private transport
that terminates TLS and forwards only to `127.0.0.1:39466`—for example, a private
overlay or an authenticated reverse tunnel. Prowl does not create or manage a tunnel.
Never forward `cli.sock` or expose the bridge directly on a LAN/public interface.

## Read-only API

Every request must send `Authorization: Bearer <access-token>`.

| Request | Result |
| --- | --- |
| `GET /v1/agents` | Active-agent summaries with opaque IDs, status, display/project/branch names, and no local paths or session files. |
| `GET /v1/agents/<opaque-id>/read?last=1…80` | The current terminal viewport for that active agent. Output is capped at 80 lines and 12 KiB UTF-8; `truncated` is `true` when either cap applies. |

The API accepts no writes: there is no endpoint for text input, keys, focus, opening,
closing, tab, or pane operations. It also does not expose scrollback or live streaming.

## Safety boundaries

- The bearer token is required even on loopback because a tunnel is a separate trust
  boundary from Prowl's same-UID CLI socket.
- The bridge uses opaque IDs that are refreshed from the current active-agent set;
  re-fetch `/v1/agents` after an agent disappears or Prowl restarts.
- Terminal text can still contain sensitive project data. Pair only a device you trust,
  protect the private tunnel, and rotate the token if it may have been disclosed.
- Turning the setting off stops the listener immediately. It retains the Keychain token
  so a trusted setup can be re-enabled; rotate it to revoke prior access.
