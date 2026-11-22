# 095.010 — P3 review fixes: token lifecycle, ordered attestation, tap ownership

## Context

The review of #1149–#1153 (round 1) found that registration and revocation were not tied
to the current settings, that concurrent management requests could break App Attest counter
order, that failed deletions were never retried, and that notification taps could lose
ownership. The fixes change the P3c–P3f design, so they are recorded here. They were made on
the top branch of the stack (#1153); the stack merges as one.

## Change

- **One token state** (`MirrorPushTokenState`, Keychain account `push-tokens`): the records
  of all Hosts and a queue of tokens to delete. Every token can be listed: a forgotten Host or
  a failed deletion is not lost.
- **Revocation is synchronous and queued.** Turning notifications off, removing every kind of a
  Host, or forgetting it moves its token to the queue at once, so a registration in flight
  cannot reuse it. The queue drains one deletion at a time. A failure keeps the rest, which
  are tried again at launch and on each return to the foreground (also while notifications are
  off; deletion is the only gateway traffic then). A `403` (the token belongs to an earlier
  installation) cannot be fixed and leaves the queue.
- **Tickets**: the global switch, each Host's revocations and each Host's kind changes have
  counters. A registration checks them after every await. It contacts the gateway, keeps a
  token, or returns `pushRegister` only while they are unchanged. A token created after a
  revocation goes to the queue. A kinds change keeps the token and drops only the stale
  message.
- **APNs token changes** move the tokens of every Host (`appBecameActive`), not only of the
  Host that connects.
- **Ordered management requests**: `MirrorPushGatewayClient` runs requests one after another,
  so assertion counters reach the gateway in order. A missing local App Attest key (after a
  reinstall, `DCError.invalidKey`) attests a new key once. A token of the earlier installation
  then answers `403` and is replaced.
- **Tap ownership**: each tap is its own request (`Target.id`). Only the request itself clears
  `pending`. A newer tap or a Host switch by the user makes an earlier request change
  nothing. A pane that is gone, or a Host that cannot be reached, shows the agents list, also
  on the same Host.

## Round 2 changes

- **Permission at the send boundary.** `MirrorPushGatewayClient` takes a `Permission` for each
  create and update. It checks it right before the request starts and again right before the
  signed request leaves, so a request that was queued before notifications were turned off is
  never sent. Deletes need no permission. (Round 3: the permission also reaches installation
  and challenge requests, so after off no request of any kind starts for a create or update;
  only a request already on the network completes.)
- **Installation recovery is a rule, not a retry.** A management `401` is read by its error
  code. `invalid-challenge` and `replayed-assertion` are retried once with a new challenge and
  the same installation. `unknown-installation` (and a missing local key) attest a new key.
  Any other `401` is an error. A new installation strands the tokens of the old one (they
  answer `403`); that happens only when the old one is gone anyway.
- **One pairing per Host carries notifications.** A Mac paired at two addresses has two device
  credentials with their own keys. The token record keeps the `deviceID` of the pairing that
  registered it, and a registration from another pairing retires the old token (the Host
  drops that registration on `410`) and creates its own. Forgetting a pairing revokes only
  its own token. A tap opens the shown entry of that Host, else a connected one, else the one
  connected most recently.
- **The APNs environment is part of a token.** The record keeps it. When another build
  replaces the app, the old token is retired and a new one is created in the new environment;
  a `PUT` never moves a token across environments.

## Round 3 changes

- **One owner per Host, also for work in flight.** Registrations of one Host run one after
  another. The push key is saved only when the registering pairing's token is committed, so a
  pairing that fails never replaces the key of the one that carries notifications. A token of
  another pairing or build stays until its replacement exists, then is deleted at once.
  Forgetting a pairing bumps its own counter, so its registration in flight stops even while
  another pairing owns the Host's token.
- **Kind changes reach every connected address of the Mac** (`MirrorHostSessions.pushSettingsChanged(hostID:)`),
  not only the entry whose settings page was used.

## Round 4 changes

- **Prepare, then commit.** A new token from the gateway is only prepared. It becomes the
  Host's owner in one synchronous step: the settings must still be current, the connection
  that asked must still be ready (`deliverable`), and the push key must be saved. Only then is
  the token that it replaces deleted. Otherwise the new token is revoked and the previous
  owner keeps working. A registration whose kinds changed while it ran keeps no new token
  (the re-registration that the change triggers creates one).

## Refs

#1153 (review round 1 of the stack review for #1149–#1153). Tests:
`MirrorPushCoordinatorTests` (off while waiting for APNs, token created after off, off and
on during a deletion, stale kinds, retry after restart, APNs change for every Host, token of
an earlier installation), `MirrorPushGatewayClientTests` (ordered requests, lost key), and
`MirrorNotificationRouterTests` (ownership).
