# Prowl Mirror for Android

Experimental **native Kotlin / Jetpack Compose** text mirror client. One application
supports Android phones and tablets (Android 8.0 / API 26 or later). At 840 dp
available width the pane drawer becomes a persistent sidebar. Both layouts share
session, protocol and rendering code; rotation is supported, not locked.

The Android project lives in `MirrorClient/Android/` in the Prowl repository.
The original Gradle project name and application ID are preserved.

## Connect

Use the matching Prowl `feat/mobile-mirror` Host with `PROWL_REMOTE_MIRROR=1`.
On Mac: Start Host → Add a Device. On Android: Add Remote Pane → enter IP/port
and the two halves of the single-use, 60-second code. After enrollment, credentials
are encrypted using Android Keystore and the short code is discarded. Pick a saved
Host and leave code blank on subsequent connections.

Select an open pane, or New Agent Pane → workspace → available Host Agent Profile
→ optional initial message. Models and permissions come from that Profile. There
is no private AI console or dependency on personal shell wrappers.

- Active text replaces the last snapshot; it is not an append-only transcript.
- Markdown emphasis/inline code, code fences and tables have readable previews;
  expanding code/table freezes the detail and supports copying the original text.
- Multiline input sends only on Send or two physical Returns within 350 ms.
  IME composition disables Send. Host checks Agent readiness through public dispatch;
  an explicitly idle Shell uses public send.
- An unconfirmed delivery preserves the draft and blocks accidental resending.
  Check receipt only queries the original request; it never repeats input.
- Retry and foreground reconnection use `ifFree`; Take Over is explicit.
- History is a bounded frozen snapshot with earlier-page loading. Returning to Live
  keeps receiving current output. Closing a mirror never stops the Host program.
- Saving credentials does not persist terminal output or drafts across process death.
  Rotation retains the current ViewModel; reopening the app offers saved Hosts.

## Build and test

Open `MirrorClient/Android/` in Android Studio, or change to that directory
and use JDK 17 and an installed Android
SDK 34. Set `ANDROID_HOME` or create an untracked `local.properties` with `sdk.dir`.

    ./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug

APK: `app/build/outputs/apk/debug/app-debug.apk`.
With an available emulator/device:

    ./gradlew :app:connectedDebugAndroidTest

Dependencies are pinned to the tested Gradle 8.7 / AGP 8.4.2 / Kotlin 1.9.24 /
Compose compiler 1.5.14 toolchain. This is not yet a Play Store release configuration.
The native TLS interop test is opt-in (`MIRROR_NATIVE_TEST_PORT`) and is skipped
without its external macOS fixture; the normal unit suite must not be described as
executing that fixture. See [validation](docs/validation.md) for actual run evidence.

## Structure

- `Wire.kt`: Swift Codable-compatible controls, bounded binary frames, public commands.
- `Transport.kt`: ECDHE-PSK TLS, challenge proof, enrollment, heartbeat and cancellation.
- `Vault.kt`: device credentials encrypted at rest with an Android Keystore key.
- `Session.kt`, `LaunchModel.kt`: subscriptions, takeover, input receipts, history and creation.
- `Document.kt`: bounded text/code/table parsing and hardware Return gesture.
- `MirrorApp.kt`: adaptive UI; `MainActivity.kt`: retained model and foreground lifecycle.

The shared [wire contract](../../docs/remote-mirror-wire.md) is owned by Prowl. There is no legacy
protocol or 64-hex-code compatibility. Update both ends together.

Source attribution and upstream terms: [ThirdPartyNotices](ThirdPartyNotices/README.md).
