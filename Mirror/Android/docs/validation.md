# Android implementation validation

Baseline: iOS `570a423`, Prowl `bbd8e6e4`. Tests do not modify either repository,
Ghostty, existing remote debug apps, or any physical device.

## Executed locally (2026-09-12)

- Debug compilation and APK packaging succeeded.
- JVM tests cover fixed binary vector/UTF-8/size rejection, pairing normalization and
  proof binding, Agent vs Shell routing, snapshot replacement/ACK, stale callbacks,
  draft revision, unknown receipt without replay, takeover, historical pagination,
  timeout overlap, Host-edit refusal and creation uncertainty after UI reopening.
- A separate local Network.framework fixture using the actual Host TLS cipher
  accepted the Android transport: short-code enrollment → HMAC proof → save → device
  PSK reconnection → authenticated pane discovery. This proves library/API wire
  interoperability, not a complete real Agent workflow. Fixture is under ignored
  `.local/` and its transient port is supplied only to the test process.
- Phone emulator application launch and screenshot inspection succeeded.
- 18 JVM tests passed with zero skips in the opt-in native fixture run:
  `/tmp/android-mirror-close-tests.log` and `app/build/test-results/testDebugUnitTest/`.
- Two instrumented UI cases passed on the Android 16 phone emulator and again
  at 1280×800 / 160 dpi wide dimensions: pairing halves remain editable; explicit
  hardware Enter down/up twice submits, one Return only adds a newline.
  Logs: `/tmp/android-mirror-close-tests.log`, `/tmp/android-mirror-tablet-tests.log`.
  The original emulator display size/density were restored afterward.
- Final APK/lint run: `/tmp/android-mirror-final-build.log`. Lint has zero errors;
  dependency age/target publishing and unused library JSSE warnings remain recorded.
- Screenshot evidence: `/tmp/android-mirror-phone2.png`, `/tmp/android-mirror-tablet.png`.
  These are layout checks, not physical tablet validation.
- Espresso was updated to 3.7.0 because Android 16 removed the reflective
  InputManager method used by older test runners. This addresses the documented
  [AndroidX Test compatibility fix](https://developer.android.com/jetpack/androidx/releases/test).
- Final independent review confirmed the listed lifecycle fixes and found no
  remaining blocker in its reviewed paths; this is not a substitute for real devices.
- Independent review compared Android to the current iOS implementation. Fixes:
  hardware Return key-up/repeat handling, explicit takeover, busy classification,
  per-request history timeout and lease reset, user-drag-only follow behavior,
  preservation of uncertain input on Host editing, 1 MiB text-frame bound, IME and
  selection cancellation, session-specific dialogs, session-owned launch state,
  and Unicode-safe detail chunking.

## Initial remote scrolling validation (2026-10-01, before button-only revision)

- Debug APK, instrumentation APK and lint succeeded with JDK 17 / Android SDK 34.
- 37 JVM tests ran: 36 passed; the optional native TLS fixture was not running,
  so its one test was skipped. Remote scroll tests cover capability negotiation,
  single in-flight requests, unchanged frames, request/lease/sequence validation,
  five-second timeout, late responses, recoverable errors, disconnect without replay,
  and preserving History access.
- All 12 instrumented UI tests passed on the Android 16 phone emulator, including
  seven remote scrolling cases. They exercise buttons/loading, unchanged output,
  top/bottom pulls, local text scrolling, reading anchors, long-press selection,
  unavailable responses, History and older Hosts. A held selection drag initially
  reproduced an unwanted remote request; it now passes without sending input.
- UI tests use a fake Host transport inside the actual application UI. They do not
  send input to any real pane or validate end-to-end scrolling over TLS.
- The emulator ran read-only with snapshot loading/saving disabled. No physical
  phone, saved Host credential or existing pane was used.
- Logs: `/tmp/prowl-android-scroll-final-build.log` and
  `/tmp/prowl-android-scroll-ui-final-direct.log`. Loading, completed, long-text,
  History and error screenshots were inspected under
  `/tmp/prowl-android-scroll-screenshots/`.

## Button-only scrolling and boundaries (2026-10-01)

- Removed remote gesture recognition and its classifier. Live remote input is now
  limited to the two top buttons; ordinary reading, edge pulls and selection remain
  local. The bottom Follow latest control is unchanged.
- Added opt-in `scroll-state-v1` metadata pairing. Only a matching lease/sequence
  commits Host boundary flags with its text frame. Missing/null flags mean unknown;
  an unchanged frame does not establish a boundary. New frames can re-enable either
  direction, and disconnect/reconnect clears old flags and pending metadata.
- JDK 17 / Android SDK 34: `:app:testDebugUnitTest :app:assembleDebug
  :app:assembleDebugAndroidTest :app:lintDebug` succeeded. 40 JVM tests ran:
  39 passed; the optional native TLS fixture test was skipped. Lint reported no
  errors and 14 existing dependency/library warnings.
- Unit coverage includes unknown/known bounds, direction-specific send guards,
  capability opt-in, frame pairing, malformed flags, duplicate/stale/wrong-lease
  metadata, missing/mismatched metadata, reconnect and older Hosts.
- All 13 instrumentation tests passed on the isolated Android 16 phone emulator,
  including eight scrolling cases. Actual Compose UI checks verify buttons above
  the reading area, Follow latest below it, top/bottom disabled states and recovery,
  local-only edge pulls/horizontal swipes/selection, loading/no-op completion,
  local reading anchors, older Hosts and unchanged History.
- The UI fixture injects Host messages through a fake transport; it does not claim
  real Host/TLS or physical-device validation. The emulator ran read-only without
  snapshots and was stopped afterward. No physical phone or real Host was touched.
- Logs: `/tmp/prowl-android-buttons-final-build.log` and
  `/tmp/prowl-android-buttons-ui.log` (`OK (13 tests)`). Boundary, loading and
  long-text screenshots were inspected under `/tmp/prowl-android-buttons-screenshots/`.

## Not represented as passed

- Physical phone/tablet, vendor-specific IME, actual Bluetooth/USB keyboard.
- Real Codex/Claude/Shell commands over a real Mac Host, cross-device takeover and
  network roaming. Client routing is independently tested; Host dispatch logic is
  not reimplemented or changed here.
- Play Store signing, current target-SDK publishing requirements and release rollout.
- App process death does not preserve output/drafts; credentials are retained.

Lint's remaining dependency-version notices reflect pinned versions. Bouncy Castle
also ships unused JSSE trust-manager classes which lint flags; runtime uses only
low-level PSK TLS with one allowed suite and a separate device-key challenge. These
warnings are documented, not suppressed as an approval claim.
