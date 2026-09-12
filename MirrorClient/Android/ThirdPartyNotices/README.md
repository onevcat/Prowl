# Source and dependency notices

This Android implementation ports the behavior and wire contract of
[Awhisper/ProwlMirror-iOS](https://github.com/Awhisper/ProwlMirror-iOS) (`570a423`)
and [Awhisper/Prowl](https://github.com/Awhisper/Prowl) (`bbd8e6e4`), derived from
[onevcat/Prowl](https://github.com/onevcat/Prowl). The upstream source terms are
preserved in [Prowl-LICENSE](Prowl-LICENSE); do not assume this code is MIT licensed.

Runtime dependencies:
- AndroidX / Jetpack Compose: Apache License 2.0.
- Kotlin and kotlinx.coroutines: Apache License 2.0.
- Gson: Apache License 2.0.
- Bouncy Castle Java libraries: [Bouncy Castle licence](https://www.bouncycastle.org/licence.html).

Android uses Bouncy Castle's low-level `PSKTlsClient`, not the JSSE trust managers
bundled in that dependency. No permissive X.509 TrustManager is installed by this app.
