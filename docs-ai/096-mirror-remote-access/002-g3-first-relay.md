# 096.002 — G3: First Relay

## Context

The plan put the first relay on a dedicated Oracle Cloud Always Free instance in Tokyo.
onevcat provided a dedicated RackNerd VPS in Los Angeles instead. It is the relay from now
on. If it is too slow or too small for real use, a second relay goes on Alibaba Cloud in
Singapore.

## Change

Deployed 2026-11-23 (infrastructure only, no Prowl code):

| Item | Value |
| --- | --- |
| Host | RackNerd VPS, Los Angeles; Ubuntu 24.04, 1 vCPU, 1 GB RAM, IPv4 only |
| Hostname | `derp-lax1.onev.dev` (A record on Cloudflare, DNS only) |
| Naming | `derp-<IATA code><index>`; a Singapore relay would be `derp-sin1` |
| Relay | `tailscale.com/cmd/derper` v1.104.7, built for linux/amd64 on the Mac |
| Service | systemd `derper`, own system user, only `CAP_NET_BIND_SERVICE` |
| Ports | 443/tcp (DERP), 3478/udp (STUN), 80/tcp (HTTP, ACME); firewall allows only these and SSH |
| Certificate | Let's Encrypt through derper's built-in ACME client; renews on its own |
| SSH | key only, password login off |

Checks done on 2026-11-23:

- `https://derp-lax1.onev.dev/derp/probe` returns 200 with a valid certificate.
- A STUN request from outside gets the mapped address.
- tailcat (`b9491c1`): a server key made with `--region=derp-lax1.onev.dev` and both sides
  forced to relay only (`TS_DEBUG_ALWAYS_USE_DERP=1`) passed data from client to server.

## Current state

G3 is not done. Still open from its acceptance list:

- Admission: `derper` runs without `--verify-client-url` because the G2 endpoint does not
  exist yet. Until then, anyone who knows the hostname can use the relay. When G2 lands, set
  `--verify-client-url` and `--verify-client-url-fail-open=false`, then test both.
- Alert when the relay is down: not set up. The plan is a scheduled probe of `/derp/probe`
  from the gateway Worker.

## Open questions

- Latency from Japan and East Asia through Los Angeles when a session cannot go direct. The
  tailcat spike measured relay-only RTT p50 43 ms through Tailscale's public relays (region
  not recorded); measure the same through `derp-lax1` during R0.
- Adding Singapore later: a tailcat address made with `--region=<hostname>` embeds that one
  relay. If the helper uses such addresses, a second relay needs new addresses. A derp map
  that we serve (`--derpmap-url`, for example from the gateway) would avoid that. Decide in R1
  (start contract) before addresses are stored on phones.
