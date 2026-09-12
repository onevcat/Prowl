# Experimental mobile mirror clients

Native clients for Prowl Remote Mirror:

- [iOS](iOS/README.md): iPhone and iPad; open `iOS/ProwlMirror-iOS.xcodeproj` in Xcode.
- [Android](Android/README.md): phones and tablets; open `Android/` in Android Studio.

Launch the matching Mac Host with `PROWL_REMOTE_MIRROR=1`. Pair via **Start Host →
Add a Device**. Both clients follow the shared [wire contract](../docs/remote-mirror-wire.md)
and [Host behavior](../docs/remote-mirror.md). Upgrade Host and clients together.

These are independent native projects within this repository. They do not add
mobile targets to the Mac Xcode project, Makefile, or release pipeline. Use each
client's documented build/test commands from its own directory. Build outputs,
SDK paths, IDE user settings and signing credentials stay untracked.

## Import provenance

The initial import preserves the tracked files and license notices from:

- [Awhisper/ProwlMirror-iOS](https://github.com/Awhisper/ProwlMirror-iOS),
  commit `570a42324ab0bbaee51266f6ecbe53c7585ba337`.
- [Awhisper/ProwMirror-Android](https://github.com/Awhisper/ProwMirror-Android),
  commit `840cfcab306b69f0f630c06578097a2852de413a`.

The original repositories retain their history. Project names and app identifiers
are preserved so relocating the source does not create a different installed app.
