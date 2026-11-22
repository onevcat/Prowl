# 095.006 — P3c: gateway client and App Attest

## Context

Third iOS slice of P3. The phone must get a push token for each Host from the gateway, and
only this app install may change or delete it (plan "Registration and revocation").

## Change

- `Mirror/Shared/MirrorPushGatewayAddress.swift`: the one gateway address
  (`https://prowl-push.onev.dev`), used by the Host's default and the phone.
- `Mirror/iOS/ProwlMirror-iOS/Infrastructure/MirrorPushGatewayClient.swift`:
  - One App Attest installation per app install (key ID and installation ID in the app's own
    Keychain group, `MirrorCredentialVault` account `push-installation`).
  - `createToken` / `updateToken` / `deleteToken` with an assertion over
    `"<METHOD> <PATH>\n<challenge>\n<body>"` and a new challenge per request.
  - A `401` drops the installation, attests a new key and retries once; a second `401`, `403`,
    `409` (too many tokens), `429` (with `Retry-After`) and malformed answers are errors.
    `DELETE` treats `404` as done. No request is sent when App Attest is not supported.
  - `MirrorAPNsEnvironment.current`: `aps-environment` from the embedded provisioning profile;
    no profile (App Store, TestFlight) means production.
- DEBUG launch environment `MIRROR_PUSH_DEBUG_GATEWAY=1`: registers, attests and prints a
  push token.

## Device check (2026-11-22, iPhone One)

- A real attestation was accepted by `prowl-push.onev.dev` and a push token issued; the
  environment read from the profile was `development`.
- `POST /v1/push` with that token and a sealed `blocked` → `202`; the notification showed
  "Prowl" / "An agent needs your attention" (read back from delivered notifications).

## Open questions

- The first push through the gateway right after installing a new build showed the fallback
  text; the same content sent again (twice) and a direct APNs push both opened. Likely the new
  extension was not ready yet; watch the first push after an install in P3d.

## Refs

PR: #1150 (stacked on #1149).
