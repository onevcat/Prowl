# Prowl Mirror for Android

Experimental **native Kotlin / Jetpack Compose** text mirror client. One application
supports Android phones and tablets (Android 8.0 / API 26 or later). On wider
windows the app centers the roster and Chat while the Terminal uses the available
width. Rotation preserves the current pane and reading position.

The Android project lives in `Mirror/Android/` in the Prowl repository.
The original Gradle project name and application ID are preserved.

## Connect

Use a Prowl Host built from the same revision (or a matching Prowl release), with
**Settings → Remote Mirror → Enable Remote Mirror** turned on.
On Mac, start listening and choose **Add a Device**. On Android, tap **Pair with a Mac**
and scan the QR code or enter the address, port and two halves of the 60-second code.
The default port is 7880. Android Keystore protects the saved device credential.

The app opens the last selected Mac's Agents screen. Use the Mac menu to switch
Hosts, add another, or rename and forget saved connections. The roster follows the
Mac's project order and can filter by Blocked, Working and Done. Shell panes are
collapsed within each project. Open a pane, or use **New Session** and select a
project, worktree, Host Agent Profile and optional initial message.

- Live text replaces the last viewport snapshot; it is not an append-only transcript.
- Markdown emphasis/inline code, code fences and tables have readable previews;
  expanding code/table freezes the detail and supports copying the original text.
- Multiline input sends only on Send or two physical Returns within 350 ms.
  IME composition disables Send. Host checks Agent readiness through shared interactive input;
  shell Send requires the Host capability and a recognized empty shell prompt. Refusals
  preserve the draft.
- An unconfirmed delivery preserves the draft and blocks accidental resending.
  Check receipt only queries the original request; it never repeats input.
- Opening a pane labeled **Mirrored elsewhere** requests takeover. Retry and
  foreground reconnection request the pane only if free.
- History is a bounded frozen snapshot with earlier-page loading. Returning to Live
  keeps receiving current output. Closing a mirror never stops the Host program.
- Hosts with `remote-scroll` show **Scroll up / Scroll down** above the Live text.
  Only these buttons send remote scroll input; swipes, edge pulls, selection and
  History remain local. **Latest** appears when reading away from the end.
  These actions scroll the actual Host pane, including a terminal application's own
  scroll handling. Host targets its pane height minus three rows (at least one row),
  with exact native scrollback movement and equivalent precision wheel input for
  applications. Internal Host profiles adjust known Agent wheel steps (Codex: three
  rows per event, reserving eight composer/status rows). Host precision-scroll
  settings and the application can affect the distance. One request runs at
  a time with a loading indicator; an unchanged screen also completes normally.
  Requests time out after five seconds and are never replayed after reconnecting.
  Hosts with `scroll-state-v1` can confirm the top/bottom boundary: the matching
  button is disabled until a newer frame permits scrolling again. Unknown bounds,
  including applications that manage their own scrolling, stay enabled; unchanged
  text alone never disables a direction. Older Hosts need no boundary metadata.
  Both directions resume reading at the top of the returned screen. Automatic
  following is paused by remote scrolling. Completion is consumed once: switching
  panes or recreating the reader preserves later local reading positions.
- Saving credentials does not persist terminal output or drafts across process death.
  Rotation retains the current ViewModel; reopening the app restores the selected Host.

## Chat and Terminal

When the Host advertises `conversation-v1` and a pane has a supported conversation,
the app opens that pane in Chat. Terminal remains available on the same connection
and is the default for other panes. Chat shows Markdown messages, grouped tool steps and expandable details and requests retained events after the last received sequence when reconnecting.
Chat and its composer expand on phones and use a centered 720 dp column on wide displays.

On Hosts with `prompt-respond`, the app can answer supported screen prompts, including
multi-select menus. Terminal offers a key bar when the Host grants key input.
A draft refusal can offer **Replace and Send** or **Bring Draft Here**, depending on
what the Host can read and clear. An uncertain delivery still requires receipt recovery.

## Build and test

Open `Mirror/Android/` in Android Studio, or change to that directory and use
Android Studio's bundled JBR or JDK 17 with an installed Android SDK 34. Set
`ANDROID_HOME` or create an untracked `local.properties` with `sdk.dir`.

    ./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug

From the repository root, `make test-mirror-android` runs the same tasks.

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

Source attribution and dependency licenses: [ThirdPartyNotices](ThirdPartyNotices/README.md).

Ordinary Send requires Host capability `agent-input`. It does not add a completion
prompt or create a pending dispatch; prior automation receipts remain unchanged.
Delivery confirmation and reconnect receipt lookup remain separate from task success.

Use **Scan QR Code** in the Host connection form to scan **Add a Device** on Host.
Scanning connects with the encoded address, port and short-lived code. Camera
permission is optional; manual entry remains available. The scanner opens in portrait
without a red scanning line. Refresh expired codes on Host.
The Terminal places **Scroll Up** and **Scroll Down** beside the lower-right edge
with loading feedback next to the controls.

## License

The Android mirror client is licensed under the [MIT License](LICENSE). This covers
`Mirror/Android/`. The rest of the repository keeps its own [license](../../LICENSE).
