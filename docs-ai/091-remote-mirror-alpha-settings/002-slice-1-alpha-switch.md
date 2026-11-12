# 091.002 — Slice 1: the alpha switch

## Context

Slice 1 of the [plan](000-plan.md): make the feature reachable without a launch wrapper,
and keep it invisible and unreachable by default.

## Change

- `GlobalSettings.remoteMirrorEnabled` (default `false`, absent key decodes to `false`) and
  the matching `SettingsFeature.State` field. The Settings binding persists it.
- `FeatureFlags.remoteMirror` and `PROWL_REMOTE_MIRROR` are removed.
- `RemoteMirrorStore.isEnabled` reads `@Shared(.settingsFile)`. The toolbar button, the
  sidebar section, the mirrored pane, and the roster sync read it.
- `MirrorHost` takes `enabled` as an autoclosure and evaluates it at each `start()`.
- `RemoteMirrorStore` subscribes to the settings publisher. When the switch goes off, it
  stops the Host, closes all outgoing mirrors, and clears the selection.
- Settings has a **Remote Mirror** section after **Commands**
  (`App/Sources/Features/Settings/Views/RemoteMirrorSettingsView.swift`) with the switch,
  an Alpha mark, and the description. **Commands** uses the `command` symbol.
- `docs/remote-mirror.md` and the `Mirror/` READMEs name the switch in place of the
  environment variable.

## Current state

The detailed controls are still in the toolbar panel. Slice 2 moves them to Settings.
