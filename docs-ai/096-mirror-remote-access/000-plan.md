# 096 — Mirror Remote Access (Mirror Pro): Plan

| | |
| --- | --- |
| **Status** | Planned |
| **Anchor date** | 2026-11-21 |
| **Primary PRs** | #1142 (plan) |
| **Related** | [095-mirror-push-notifications](../095-mirror-push-notifications/000-plan.md), [091-remote-mirror-alpha-settings](../091-remote-mirror-alpha-settings/000-plan.md), `docs/remote-mirror.md` |

## Background

Today the phone reaches the Mac only on the same network or through a network the user set
up (Tailscale or similar). With push notifications (095), an alert reaches the phone anywhere,
but the user without such a network cannot act on it. "Handle your agents from anywhere, with
no network setup" is the thing users pay for, and it is a server service, so it is allowed
under App Review Guidelines 3.1.2(a) and 4.10. It is the **Mirror Pro** subscription of the
iOS app. Prowl for Mac stays free and has no entitlement check: the relays decide who may use
them.

[tailcat](https://github.com/tailscale/tailcat) (BSD-3-Clause, by Tailscale) gives the
transport: WireGuard tunnels with NAT traversal, DERP relays as the fallback, no accounts, and
an official Swift package (`TailcatKit`, macOS 14+, iOS 17+) over a C API.

## Goals

- A Pro user reaches a paired Mac from a cellular network with no setup beyond pairing.
- Users who do not use it never get, start or contact any part of it: no tunnel process, no
  relay traffic, and on the Mac not even the binary (see Delivery).
- The existing Mirror protocol, TLS-PSK and device proof run unchanged inside the tunnel.
- LAN and user-managed networks stay free and unchanged.

### Non-goals

- Using Tailscale's public tailcat relays in the product. They are rate-limited, keep
  metadata logs, and are not meant for this use. Only the spike used them.
- A lifetime purchase at launch: the relay cost per subscriber is not known yet.
- Keeping the Mac awake while agents work. Useful for this feature, but planned separately.

## Design / Approach

### Parts

| Part | Where | Role |
| --- | --- | --- |
| Tunnel helper `prowl-mirror-tunnel` | separate executable, downloaded on demand | `TailcatServer`; forwards the tunnel port to the Host listener on loopback |
| Host | `App/Sources/Features/RemoteMirror/` | Starts and stops the helper, gives it the identity and the allowed device keys, hands the tailcat address to the phone |
| iOS client | `Mirror/iOS/` | `TailcatClient`; uses the tunnel when the LAN address does not answer |
| Relays | `derper` on our servers | DERP relays and STUN; admission only for entitled nodes |
| Gateway | Cloudflare Workers (shared with 095) | Admission decisions for the relays from RevenueCat entitlements |

### Delivery on the Mac and when anything runs

The Mac app does not link Go and does not ship tailcat. The helper is a separate, signed and
notarized executable, built per architecture and published as a release asset. Each app
version pins the helper version and its SHA-256.

- The download happens only when the user turns on **Remote Access (Mirror Pro)** in the
  Remote Mirror settings (off by default). This switch is the first and main entry point.
  The helper is stored in the app's Application Support folder, which the user can write, so
  the app checks the hash and the code signature (same Team ID) **before every start**, not
  only after the download. When an app update pins a new helper version, the app downloads it
  at the next start of the feature and deletes the old one. A **Remove** control deletes it.
- The phone cannot turn the feature on for the Mac. After a purchase, while on the LAN, the
  phone can send a request; the Mac shows a confirmation, and only the Mac user's consent
  starts the download.
- The helper process runs only while all are true: Remote Mirror is on and the Host runs;
  **Remote Access** is on; at least one paired device registered remote access. Turning any of
  them off stops the process at once.
- The iOS app (App Store, so no downloaded code, Guideline 2.5.2) bundles `TailcatKit`, but
  creates no tailcat client unless the user has Pro and turned remote access on for that Host.

### Connection

1. While on the LAN, a Pro phone sends `remoteRegister {nodeKey}` (its tailcat public key),
   only when the Host advertises the `remote-v1` capability. The Host stores the key, starts
   the helper if this was the missing condition, adds the key to `allowedClients`, and replies
   with its tailcat address and node key. The phone keeps the address in the Keychain (the
   address grants access; treat it as a secret).
2. The phone then registers both node keys with the gateway (see Relays and admission). Until
   that is done, the relays refuse the helper, which retries.
3. The helper runs `TailcatServer` with a persistent identity (private key in the Mac
   Keychain, passed to the helper at start) and the derp map of our relays. It accepts on one
   tunnel port and forwards to the Host listener on `127.0.0.1`.
4. The phone tries the LAN address first, then the tunnel. The iOS transport reads and writes
   a `TailcatKit` `Connection` under the existing TLS-PSK session.
5. If a reused client times out (for example after the helper restarted), the app drops it
   and makes a new one at once, instead of waiting for the full timeout.

### Relays and admission

- `derper` needs a long-running process with TCP 443 and UDP 3478, so it cannot run on
  Workers. First relay: a dedicated Oracle Cloud Always Free instance in Tokyo, not shared with
  other services. A second region on a small paid server when subscribers need it.
- Admission: `derper` asks the gateway whether a node key may connect (client verification
  URL; to verify in R0). The phone registers its node key and the Host's node key with the
  gateway together with its RevenueCat app user ID; the gateway allows both keys while the
  entitlement is active.
- Most sessions go direct after NAT traversal; relays carry bootstrap and the rest.
- The relays check a node only when it connects. When a subscription ends, the change takes
  effect at the next connection; a session that is already up is not cut.
- Revocation: unpairing a device on the Mac removes its key from `allowedClients` at once and
  asks the gateway (through the phone, or at the next relay admission check) to drop it. A
  phone that turns remote access off deletes its keys at the gateway.
- `docs/remote-mirror.md` lists what the relays and the gateway see: node keys, IP addresses,
  connection times, the RevenueCat app user ID; never terminal content (it is inside
  WireGuard and TLS-PSK).

### Subscription

- RevenueCat, monthly and yearly with a free trial. No account.
- 3.1.2(a) requires the subscription on all of the user's devices. Define in R3 how restore
  works for an iPhone and an iPad on the same Apple ID (RevenueCat restore behavior and app
  user IDs), and test: two devices, reinstall, refund, removing one device.
- The Mac setting is the entry point on the Mac: with **Remote Access** off, a short text says
  that it needs Mirror Pro in the iOS app and links to the App Store page. The phone shows a
  paywall when the Host advertises `remote-v1` and the user has no Pro.

## Slices

| Slice | Content |
| --- | --- |
| R0 | Spikes: `derper` client verification against a Worker; helper download, hash and signature check, Gatekeeper with and without network, start and stop |
| R1 | Mac: helper target and release asset, Remote Access setting, download and removal, process lifecycle, `remote-v1`, `remoteRegister` |
| R2 | iOS: tunnel transport, LAN-then-tunnel connection, client rebuild on failure |
| R3 | Gateway admission, RevenueCat, paywall, multi-device rules, privacy manifest and App Store privacy labels |
| R4 | Relay deployment (Oracle Tokyo), derp map, monitoring |

## Alternatives & decisions

- **tailcat** — chosen over building a relay. It gives NAT traversal and a relay fallback,
  with an official Swift package and no accounts.
- **Helper process, downloaded on demand** — chosen. Nothing tunnel-related is in the Mac app
  until the user asks for it, which keeps security reviews of the app simple, and Go stays out
  of the app process. A thin per-architecture download is also smaller than a universal
  bundle. Most users will never use remote access, so bundling would cost every user about
  12 MB of download and a tunnel binary in every install, while the risks of downloading fall
  only on users who turn the feature on. For networks that block the download, the setting
  also accepts the helper as a file that the user downloaded from the release page (same hash
  and signature checks). Bundling it, never started unless the conditions above hold, stays
  the fallback only if R0 shows that downloading fails broadly. R0 checks: endpoint security tools treat "download, then run" as
  a dropper pattern and may block or flag it more than a bundled binary; company proxies may
  block the asset host; binary allowlisting (for example Santa) may refuse an executable in a
  user-writable folder; Gatekeeper must accept the notarized helper with and without network
  (a bare executable cannot carry a stapled ticket).
- **Own relays with admission** — chosen. Public relays are not for products, and admission at
  the relay is what makes the subscription meaningful while the Mac stays free.
- **Remote access as the paid product** — chosen over paid push (Guideline 4.10).

## Spike results (2026-11-21)

TailcatKit from tailcat `e99a945`, iPhone One (iPhone 15 Pro Max, iOS 27.2.1), Mac on a home
Wi-Fi network, Tailscale's public relays, one echo server on the Mac.

| Case | Path | Connect | RTT p50 / p90 | 2 MB download |
| --- | --- | --- | --- | --- |
| Same Wi-Fi | LAN, direct | 75 ms | 7 / 9 ms | 21 Mbit/s |
| 5G, new client | direct (NAT traversal) | 147 ms | 51 / 69 ms | 8.5 Mbit/s |
| 5G, reused client | direct | 39 ms | 40 / 50 ms | 16.5 Mbit/s |
| 5G, after 171 s locked | direct, reused client | 54 ms | 42 / 54 ms | 2.2 Mbit/s |
| 5G, relay only (`TS_DEBUG_ALWAYS_USE_DERP`) | DERP | 59 ms | 43 / 70 ms | 6.3 Mbit/s |

- Building the XCFramework (`make xcframework` in `swift/`) took 85 s with Go 1.27.
- Size: a stripped arm64 binary with TailcatKit is about 15.7 MB (about 6 MB compressed). A
  universal Mac helper would be about 31 MB (about 12 MB compressed), against a 34 MB DMG.
- After the server restarted, a reused client timed out (20 s); a new client connected.

## Open questions

- Whether `derper` client verification can call an HTTPS endpoint as planned.
- How the helper receives its private key safely (stdin, XPC, or a Keychain item it can read).
- Battery cost of a long-lived tunnel on the phone.
- Whether `derper` can re-check admission for long-lived connections, if cutting them at the
  end of a subscription turns out to matter.
- Android: `libtailcat` builds for Android; the client is not in scope of this plan.

## Amendments
