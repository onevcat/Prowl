# 075.002 — S1: Dedicated Ghostty config file (#693)

## Context

First slice of the plan: let Prowl use one Ghostty config file of its own instead of the files
it shares with standalone Ghostty. It also gives slice S2 a single place that knows which files
the user's config comes from.

## Change

- `GhosttyConfigSource` (`App/Sources/Infrastructure/Ghostty/GhosttyConfigSource.swift`) loads
  `.ghosttyDefault` with `ghostty_config_load_default_files` and `.file(path:)` with
  `ghostty_config_load_file`, then the recursive `config-file` includes. A missing dedicated
  file loads nothing.
- `GhosttyRuntime.makeConfig(source:overrideFileURLs:)` is now the only config builder. The
  initial load, `reloadConfig(soft: false)`, and `applyRuntimeOverridesIfNeeded` use it.
  `setConfigSource(_:)` reloads running terminals and runs the theme fallback again.
- Theme fallback: `ghostty +show-config` accepts only its own flags and always reads the
  default files, so a dedicated file is resolved in process
  (`GhosttyRuntime.userConfigSnapshot(loading:)`). The shared source keeps the CLI probe, so
  its behavior does not change for users without the Ghostty app. For both sources the raw
  `theme` spec (which keeps a same-name light/dark pair) comes from `GhosttyRawConfig`: the
  source's files and their `config-file` includes in Ghostty's load order, last value wins.
  Before review round 1 it read only one root file, so a light/dark pair set in an include
  was missed and the fallback could replace it.
- **Open Config**, Ghostty's `open_config` action, and `prowl-split-divider-width` use the
  active source's file (`editableFilePath`). Open Config creates a missing dedicated file.
- Settings: `GlobalSettings.ghosttyConfigPath`, `SettingsFeature.setGhosttyConfigPath`
  (trimmed; blank means shared), and the **Terminal Config** section
  (`TerminalConfigSettingsSection`) on Settings → General. The app scene pushes the setting to
  the runtime on appear and on change.

## Verification

- Unit tests: `GhosttyConfigSourceTests` (replacement, includes, missing file, override order,
  in-process snapshot), `SettingsFeatureTests.setGhosttyConfigPathNormalizesAndPersists`,
  `SettingsFilePersistenceTests.ghosttyConfigPathRoundTripsAndDefaultsToSharedConfig`.
- Debug instance with a temporary home: the shared config set `background = #002b36`, the
  dedicated file `background = #3b1f2b`. The terminal showed the dedicated color; **Use
  Ghostty's Config** switched the running terminal to the shared color and cleared the setting.

## Refs

PR: (this slice)
