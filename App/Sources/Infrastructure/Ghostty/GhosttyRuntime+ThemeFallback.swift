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
    Task { [weak self] in
      let snapshot = await Self.probeUserConfigSnapshot()
      let pair: GhosttyThemePair? =
        snapshot?.themeMode.allowsMismatchFallback == true ? await Self.probeFallbackThemePair() : nil
      self?.applyResolvedThemeFallback(for: scheme, snapshot: snapshot, pair: pair)
    }
  }

  @MainActor
  func applyResolvedThemeFallback(
    for scheme: ColorScheme,
    snapshot: GhosttyUserConfigSnapshot?,
    pair: GhosttyThemePair?
  ) {
    guard currentColorScheme == scheme else { return }
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

    guard let updated = ghostty_config_new() else { return }
    ghostty_config_load_default_files(updated)
    ghostty_config_load_recursive_files(updated)
    ghostty_config_load_cli_args(updated)
    Self.loadTerminalProgramOverrides(into: updated)
    for url in overrideURLs {
      url.path.withCString { path in
        ghostty_config_load_file(updated, path)
      }
    }
    ghostty_config_finalize(updated)
    ghostty_app_update_config(app, updated)
    if let clone = ghostty_config_clone(updated) {
      setConfig(clone)
    }
    ghostty_config_free(updated)
    runtimeOverrideSignature = nextSignature
    onConfigChange?()
    NotificationCenter.default.post(name: .ghosttyRuntimeConfigDidChange, object: self)
  }

  nonisolated static func probeUserConfigSnapshot() async -> GhosttyUserConfigSnapshot? {
    // `await` ensures this runs on a cooperative executor rather than on the
    // caller's MainActor, so the synchronous subprocess calls below never block
    // the main thread.
    await Task.yield()
    return userConfigSnapshotFromCLI()
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
    // config text when we can read it. The background tone still comes from the
    // resolved CLI output.
    guard let rawMode = rawUserThemeMode() else { return snapshot }
    return GhosttyUserConfigSnapshot(themeMode: rawMode, backgroundTone: snapshot.backgroundTone)
  }

  nonisolated static func rawUserThemeMode() -> GhosttyThemeMode? {
    guard let url = preferredGhosttyConfigURL(),
      let contents = try? String(contentsOf: url, encoding: .utf8),
      let spec = GhosttyUserConfigSnapshot.rawThemeSpec(fromConfig: contents)
    else { return nil }
    return GhosttyUserConfigSnapshot.parseThemeMode(from: spec)
  }

  /// Mirrors Ghostty's macOS default-config selection: prefer the Application
  /// Support file when present, otherwise fall back to the XDG config. Within
  /// each location the modern `config.ghostty` wins over the legacy `config`.
  /// `theme` set through `config-file` includes isn't resolved here; those rare
  /// setups simply keep the previous `+show-config` behavior.
  nonisolated static func preferredGhosttyConfigURL() -> URL? {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser

    let appSupport = home.appending(
      path: "Library/Application Support/com.mitchellh.ghostty",
      directoryHint: .isDirectory
    )
    let xdgRoot: URL
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      xdgRoot = URL(fileURLWithPath: xdg, isDirectory: true)
    } else {
      xdgRoot = home.appending(path: ".config", directoryHint: .isDirectory)
    }
    let xdg = xdgRoot.appending(path: "ghostty", directoryHint: .isDirectory)

    let candidates = [
      appSupport.appending(path: "config.ghostty"),
      appSupport.appending(path: "config"),
      xdg.appending(path: "config.ghostty"),
      xdg.appending(path: "config"),
    ]
    return candidates.first { fileManager.fileExists(atPath: $0.path) }
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
