import AppKit
import GhosttyKit
import SwiftUI

extension GhosttyRuntime {
  func reconcileThemeFallback(for scheme: ColorScheme) {
    // Subprocess discovery of the user's Ghostty CLI can block the main
    // thread (and in XCTest host bringup it has timed out the test runner
    // preparation phase). Short-circuit under test, and dispatch the
    // lookup off-main in all other cases.
    guard !Self.isRunningInTestEnvironment() else {
      setThemeFallbackOverride("")
      return
    }
    let source = configSource
    Task { [weak self] in
      let snapshot = await Self.probeUserConfigSnapshot(source: source)
      let pair: GhosttyThemePair? =
        snapshot?.themeMode.allowsMismatchFallback == true ? await Self.probeFallbackThemePair() : nil
      self?.applyResolvedThemeFallback(for: scheme, source: source, snapshot: snapshot, pair: pair)
    }
  }

  @MainActor
  func applyResolvedThemeFallback(
    for scheme: ColorScheme,
    source: GhosttyConfigSource,
    snapshot: GhosttyUserConfigSnapshot?,
    pair: GhosttyThemePair?
  ) {
    guard currentColorScheme == scheme, configSource == source else { return }
    // `.none` (no user theme) is treated like a single dark theme here: Ghostty's
    // no-theme default is the fixed dark `#282C34` reported by `+show-config`, so
    // its `backgroundTone` resolves to `.dark` and adapts to a light app the same
    // way an explicit single dark theme does. `.dual` is the user's explicit
    // per-mode choice and is always respected.
    guard let snapshot, snapshot.themeMode.allowsMismatchFallback else {
      setThemeFallbackOverride("")
      return
    }

    let targetTone: GhosttyTerminalTone = scheme == .dark ? .dark : .light
    guard snapshot.backgroundTone == .light || snapshot.backgroundTone == .dark else {
      setThemeFallbackOverride("")
      return
    }

    if snapshot.backgroundTone == targetTone {
      setThemeFallbackOverride("")
      return
    }

    guard let pair else {
      setThemeFallbackOverride("")
      return
    }

    setThemeFallbackOverride("theme = light:\(pair.light),dark:\(pair.dark)")
  }

  nonisolated static func isRunningInTestEnvironment() -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env["XCTestConfigurationFilePath"] != nil
      || env["XCTestBundlePath"] != nil
      || env["XCTestSessionIdentifier"] != nil
  }

  func setThemeFallbackOverride(_ contents: String) {
    guard contents != themeFallbackOverrideContents else { return }
    themeFallbackOverrideContents = contents
    applyRuntimeOverridesIfNeeded()
  }

  func applyRuntimeOverridesIfNeeded() {
    guard let app else { return }

    let nextSignature = [appKeybindOverrideContents, themeFallbackOverrideContents].joined(separator: "\n---\n")
    guard nextSignature != runtimeOverrideSignature else { return }

    var overrideURLs: [URL] = []
    if !appKeybindOverrideContents.isEmpty {
      let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("prowl-ghostty-keybind-overrides.conf")
      do {
        try appKeybindOverrideContents.write(to: url, atomically: true, encoding: .utf8)
        overrideURLs.append(url)
      } catch {
        ghosttyLogger.warning("Failed to write ghostty keybind override file: \(error.localizedDescription)")
        return
      }
    }

    if !themeFallbackOverrideContents.isEmpty {
      let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("prowl-ghostty-theme-overrides.conf")
      do {
        try themeFallbackOverrideContents.write(to: url, atomically: true, encoding: .utf8)
        overrideURLs.append(url)
      } catch {
        ghosttyLogger.warning("Failed to write ghostty theme override file: \(error.localizedDescription)")
        return
      }
    }

    guard let updated = Self.makeConfig(source: configSource, overrideFileURLs: overrideURLs) else { return }
    ghostty_app_update_config(app, updated)
    if let clone = ghostty_config_clone(updated) {
      setConfig(clone)
    }
    ghostty_config_free(updated)
    runtimeOverrideSignature = nextSignature
    onConfigChange?()
    NotificationCenter.default.post(name: .ghosttyRuntimeConfigDidChange, object: self)
  }

  nonisolated static func probeUserConfigSnapshot(source: GhosttyConfigSource) async -> GhosttyUserConfigSnapshot? {
    // `await` ensures this runs on a cooperative executor rather than on the
    // caller's MainActor, so the synchronous subprocess calls below never block
    // the main thread.
    await Task.yield()
    switch source {
    case .ghosttyDefault:
      return userConfigSnapshotFromCLI()
    case .file:
      // `ghostty +show-config` only reads Ghostty's default files, so a
      // dedicated file is resolved in process instead.
      return userConfigSnapshot(loading: source)
    }
  }

  /// Resolves the background of `source` alone, without Prowl's overrides.
  nonisolated static func userConfigSnapshot(loading source: GhosttyConfigSource) -> GhosttyUserConfigSnapshot? {
    guard let config = ghostty_config_new() else { return nil }
    defer { ghostty_config_free(config) }
    source.load(into: config)
    ghostty_config_finalize(config)

    var color = ghostty_config_color_s()
    let key = "background"
    let backgroundTone: GhosttyTerminalTone =
      ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8)))
      ? GhosttyUserConfigSnapshot.classifyBackgroundTone(of: NSColor(ghostty: color))
      : .unknown
    return GhosttyUserConfigSnapshot(
      themeMode: rawUserThemeMode(source: source) ?? .none,
      backgroundTone: backgroundTone
    )
  }

  nonisolated static func probeFallbackThemePair() async -> GhosttyThemePair? {
    await Task.yield()
    return resolveFallbackThemePair()
  }

  nonisolated static func userConfigSnapshotFromCLI() -> GhosttyUserConfigSnapshot? {
    guard let output = runGhosttyCommand(arguments: ["+show-config"]) else { return nil }
    let snapshot = GhosttyUserConfigSnapshot.parse(showConfigOutput: output)

    // `ghostty +show-config` collapses an explicit same-name light/dark pair
    // (`theme = light:X,dark:X`) back into a single `theme = X`. Trusting that
    // alone would make us apply the single-theme fallback over the user's
    // explicit light/dark choice, so re-derive the theme mode from the raw
    // config text when it sets one. The background tone still comes from the
    // resolved CLI output.
    guard let rawMode = rawUserThemeMode(source: .ghosttyDefault) else { return snapshot }
    return GhosttyUserConfigSnapshot(themeMode: rawMode, backgroundTone: snapshot.backgroundTone)
  }

  /// The `theme` as written, from the source's files and their includes; the last
  /// one wins, as in Ghostty. `+show-config` collapses `light:X,dark:X` to `X`, so
  /// the raw text decides whether the user chose a light/dark pair.
  nonisolated static func rawUserThemeMode(source: GhosttyConfigSource) -> GhosttyThemeMode? {
    guard let spec = GhosttyRawConfig.lastValue(of: "theme", files: source.userConfigFileURLs) else {
      return nil
    }
    return GhosttyUserConfigSnapshot.parseThemeMode(from: spec)
  }

  /// Ghostty's default config files in the order it loads them: XDG before
  /// Application Support, and the legacy `config` before `config.ghostty` in each.
  nonisolated static func defaultGhosttyConfigFileURLs() -> [URL] {
    let appSupport = FileManager.default.homeDirectoryForCurrentUser.appending(
      path: "Library/Application Support/com.mitchellh.ghostty",
      directoryHint: .isDirectory
    )
    let xdg = ghosttyXDGConfigDirectory()
    return [
      xdg.appending(path: "config"),
      xdg.appending(path: "config.ghostty"),
      appSupport.appending(path: "config"),
      appSupport.appending(path: "config.ghostty"),
    ]
  }

  /// Where Ghostty looks for a theme name, in order: the user's XDG themes
  /// folder, then the bundled resources (`GHOSTTY_RESOURCES_DIR`).
  nonisolated static func ghosttyThemeDirectories() -> [URL] {
    var directories = [ghosttyXDGConfigDirectory().appending(path: "themes", directoryHint: .isDirectory)]
    if let resources = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"], !resources.isEmpty {
      directories.append(URL(fileURLWithPath: resources, isDirectory: true).appending(path: "themes"))
    }
    return directories
  }

  /// `$XDG_CONFIG_HOME/ghostty`, or `~/.config/ghostty` when it is not set.
  private nonisolated static func ghosttyXDGConfigDirectory() -> URL {
    let root: URL
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      root = URL(fileURLWithPath: xdg, isDirectory: true)
    } else {
      root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
    }
    return root.appending(path: "ghostty", directoryHint: .isDirectory)
  }

  nonisolated static func runGhosttyCommand(arguments: [String]) -> String? {
    guard let executablePath = resolveGhosttyExecutablePath() else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      let command = arguments.joined(separator: " ")
      ghosttyLogger.warning(
        "Failed to run ghostty command \(command): \(error.localizedDescription)"
      )
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    guard !data.isEmpty else { return "" }
    return String(data: data, encoding: .utf8)
  }

  nonisolated static func resolveGhosttyExecutablePath() -> String? {
    ghosttyCLICacheLock.lock()
    if let cachedGhosttyExecutablePath,
      FileManager.default.isExecutableFile(atPath: cachedGhosttyExecutablePath)
    {
      defer { ghosttyCLICacheLock.unlock() }
      return cachedGhosttyExecutablePath
    }
    if ghosttyExecutableResolutionAttempted {
      ghosttyCLICacheLock.unlock()
      return nil
    }
    ghosttyCLICacheLock.unlock()

    var resolvedPath: String?
    for candidate in ghosttyExecutableCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
      resolvedPath = candidate
      break
    }

    if resolvedPath == nil {
      let which = Process()
      which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
      which.arguments = ["ghostty"]
      let outputPipe = Pipe()
      which.standardOutput = outputPipe
      which.standardError = Pipe()
      do {
        try which.run()
        which.waitUntilExit()
      } catch {
        ghosttyCLICacheLock.lock()
        ghosttyExecutableResolutionAttempted = true
        ghosttyCLICacheLock.unlock()
        return nil
      }

      if which.terminationStatus == 0 {
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty,
          FileManager.default.isExecutableFile(atPath: path)
        {
          resolvedPath = path
        }
      }
    }

    ghosttyCLICacheLock.lock()
    defer { ghosttyCLICacheLock.unlock() }
    ghosttyExecutableResolutionAttempted = true
    cachedGhosttyExecutablePath = resolvedPath
    return resolvedPath
  }

  nonisolated static func resolveFallbackThemePair() -> GhosttyThemePair? {
    ghosttyCLICacheLock.lock()
    if let cachedFallbackThemePair {
      defer { ghosttyCLICacheLock.unlock() }
      return cachedFallbackThemePair
    }
    ghosttyCLICacheLock.unlock()

    let knownLightCandidates = ["Ghostty Default Style Light", "Catppuccin Latte"]
    let knownDarkCandidates = ["Ghostty Default Style Dark", "Catppuccin Frappe"]

    var resolvedPair: GhosttyThemePair?
    if let output = runGhosttyCommand(arguments: ["+list-themes"]) {
      let availableThemes = Set(
        output
          .split(whereSeparator: \.isNewline)
          .map { line -> String in
            let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = raw.lastIndex(of: "("), raw.hasSuffix(")") {
              return String(raw[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return raw
          }
          .filter { !$0.isEmpty }
      )

      if let light = knownLightCandidates.first(where: { availableThemes.contains($0) }),
        let dark = knownDarkCandidates.first(where: { availableThemes.contains($0) })
      {
        resolvedPair = GhosttyThemePair(light: light, dark: dark)
      }
    }

    let pair =
      resolvedPair
      ?? GhosttyThemePair(light: "Catppuccin Latte", dark: "Ghostty Default Style Dark")
    ghosttyCLICacheLock.lock()
    cachedFallbackThemePair = pair
    ghosttyCLICacheLock.unlock()
    return pair
  }
}
