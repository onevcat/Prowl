# Source and dependency notices

This Android implementation ports the behavior and wire contract of
[Awhisper/ProwlMirror-iOS](https://github.com/Awhisper/ProwlMirror-iOS) (`570a423`)
and [Awhisper/Prowl](https://github.com/Awhisper/Prowl) (`bbd8e6e4`), derived from
the Remote Mirror sources of [onevcat/Prowl](https://github.com/onevcat/Prowl). Like the
iOS mirror client, it is licensed under the [MIT License](../LICENSE).

Runtime dependencies:
- AndroidX / Jetpack Compose: Apache License 2.0.
- Kotlin and kotlinx.coroutines: Apache License 2.0.
- Gson: Apache License 2.0.
- ZXing Android Embedded and ZXing Core: Apache License 2.0.
- Bouncy Castle Java libraries: [Bouncy Castle licence](https://www.bouncycastle.org/licence.html).

Android uses Bouncy Castle's low-level `PSKTlsClient`, not the JSSE trust managers
bundled in that dependency. No permissive X.509 TrustManager is installed by this app.

Agent icons: the `agent_*.xml` drawables come from Lobe Icons, Pi, Oh My Pi, Qwen Code
(MIT) and Simple Icons (CC0). [agent-icons.txt](agent-icons.txt) holds the MIT notices,
and the APK ships it as `assets/THIRD_PARTY_NOTICES`. For the source of each icon, see
[CommandIcons/README.md](../../../App/Sources/Assets.xcassets/CommandIcons/README.md).
