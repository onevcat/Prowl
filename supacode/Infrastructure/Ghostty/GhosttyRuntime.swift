import AppKit
import GhosttyKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated let ghosttyLogger = SupaLogger("GhosttyRuntime")

// Explicitly isolated rather than relying on the module's MainActor default:
// when a Release (whole-module) build's swiftmodule is deserialized by the test
// target, default-isolation inference is lost for the `isolated deinit` check
// and compilation fails with "containing class is not isolated to an actor".
// The explicit attribute is semantically identical and serializes correctly.
@MainActor
final class GhosttyRuntime {
  nonisolated static let ghosttyExecutableCandidates = [
    "/Applications/Ghostty.app/Contents/MacOS/ghostty",
    "/opt/homebrew/bin/ghostty",
    "/usr/local/bin/ghostty",
  ]
  nonisolated static let ghosttyCLICacheLock = NSLock()
  nonisolated(unsafe) static var cachedGhosttyExecutablePath: String?
  nonisolated(unsafe) static var ghosttyExecutableResolutionAttempted = false
  nonisolated(unsafe) static var cachedFallbackThemePair: GhosttyThemePair?
  // Prowl constructs a single GhosttyRuntime for the whole app lifetime
  // (see `supacodeApp.init`). This weak reference gives UI surfaces that
  // don't otherwise have access to the runtime (e.g. the Settings window) a
  // direct way to trigger app-level actions without threading the instance
  // through SwiftUI's environment or reducers.
  static weak var shared: GhosttyRuntime?

  final class SurfaceReference {
    let surface: ghostty_surface_t
    var isValid = true

    init(_ surface: ghostty_surface_t) {
      self.surface = surface
    }

    func invalidate() {
      isValid = false
    }
  }

  var config: ghostty_config_t?
  private(set) var configPath: String?
  private(set) var app: ghostty_app_t?
  var observers: [NSObjectProtocol] = []
  var surfaceRefs: [SurfaceReference] = []
  var lastColorScheme: ghostty_color_scheme_e?
  var currentColorScheme: ColorScheme?
  var appKeybindOverrideContents = ""
  var appKeybindOverrideEntries: [String] = []
  var themeFallbackOverrideContents = ""
  var runtimeOverrideSignature = ""
  var onConfigChange: (() -> Void)?
  var onQuit: (() -> Void)?

  init(initialColorScheme: ColorScheme? = nil, configPath: String? = nil) {
    let configPath = Self.normalizedConfigPath(configPath)
    guard let config = Self.loadConfig(at: configPath) else {
      preconditionFailure("ghostty_config_new failed")
    }
    self.configPath = configPath
    self.config = config

    var runtimeConfig = ghostty_runtime_config_s(
      userdata: Unmanaged.passUnretained(self).toOpaque(),
      supports_selection_clipboard: true,
      wakeup_cb: { @Sendable userdata in
        GhosttyRuntime.wakeupCallback(userdata)
      },
      action_cb: { @Sendable app, target, action in
        GhosttyRuntime.actionCallback(app, target, action)
      },
      read_clipboard_cb: { @Sendable userdata, location, state in
        GhosttyRuntime.readClipboardCallback(userdata, location, state)
      },
      confirm_read_clipboard_cb: { @Sendable userdata, string, state, request in
        GhosttyRuntime.confirmReadClipboardCallback(userdata, string, state, request)
      },
      write_clipboard_cb: { @Sendable userdata, location, content, len, confirm in
        GhosttyRuntime.writeClipboardCallback(userdata, location, content, len, confirm)
      },
      close_surface_cb: { @Sendable userdata, processAlive in
        GhosttyRuntime.closeSurfaceCallback(userdata, processAlive)
      }
    )

    guard let app = ghostty_app_new(&runtimeConfig, config) else {
      preconditionFailure("ghostty_app_new failed")
    }
    self.app = app
    if let initialColorScheme {
      setColorScheme(initialColorScheme)
    }

    Self.shared = self
    registerNotificationObservers()
  }

  var appliedColorSchemeForTesting: ColorScheme? {
    currentColorScheme
  }

  func registerNotificationObservers() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.setAppFocus(true)
        }
      })
    observers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.setAppFocus(false)
        }
      })
    observers.append(
      center.addObserver(
        forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let app = self?.app else { return }
          ghostty_app_keyboard_changed(app)
        }
      })

    let workspaceCenter = NSWorkspace.shared.notificationCenter
    observers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.logLifecycleEvent("workspaceWillSleep")
        }
      })
    observers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.logLifecycleEvent("workspaceDidWake")
        }
      })
    observers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.screensDidSleepNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.logLifecycleEvent("screensDidSleep")
        }
      })
    observers.append(
      workspaceCenter.addObserver(
        forName: NSWorkspace.screensDidWakeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.logLifecycleEvent("screensDidWake")
        }
      })
  }

  isolated deinit {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    if let app {
      ghostty_app_free(app)
    }
    if let config {
      ghostty_config_free(config)
    }
  }

  func setAppFocus(_ focused: Bool) {
    if let app {
      ghostty_app_set_focus(app, focused)
    }
  }

  func tick() {
    if let app {
      ghostty_app_tick(app)
    }
  }

  func logLifecycleEvent(_ event: String) {
    let validSurfaceCount = surfaceRefs.reduce(into: 0) { count, ref in
      if ref.isValid {
        count += 1
      }
    }
    ghosttyLogger.info(
      "[TerminalWake] event=\(event) appActive=\(NSApp.isActive) "
        + "windows=\(NSApp.windows.count) runtimeSurfaces=\(validSurfaceCount)"
    )
  }

  func setColorScheme(_ scheme: ColorScheme) {
    guard let app else { return }
    currentColorScheme = scheme
    let ghosttyScheme: ghostty_color_scheme_e =
      scheme == .dark
      ? GHOSTTY_COLOR_SCHEME_DARK
      : GHOSTTY_COLOR_SCHEME_LIGHT
    lastColorScheme = ghosttyScheme
    ghostty_app_set_color_scheme(app, ghosttyScheme)
    applyColorSchemeToSurfaces(ghosttyScheme)
    reconcileThemeFallback(for: scheme)
  }

  func registerSurface(_ surface: ghostty_surface_t) -> SurfaceReference {
    let ref = SurfaceReference(surface)
    surfaceRefs.append(ref)
    surfaceRefs = surfaceRefs.filter { $0.isValid }
    if let lastColorScheme {
      ghostty_surface_set_color_scheme(surface, lastColorScheme)
    }
    return ref
  }

  func unregisterSurface(_ ref: SurfaceReference) {
    ref.invalidate()
    surfaceRefs = surfaceRefs.filter { $0.isValid }
  }

  func reloadConfig(soft: Bool, target: ghostty_target_s) {
    guard let app else { return }
    if soft, let config {
      guard let clone = ghostty_config_clone(config) else { return }
      applyConfig(clone, target: target, app: app)
      ghostty_config_free(clone)
      return
    }
    guard let config = Self.loadConfig(at: configPath) else { return }
    applyConfig(config, target: target, app: app)
    ghostty_config_free(config)
  }

  /// Re-reads the user's Ghostty config from disk and re-applies Prowl's
  /// runtime overrides on top of it. Intended for the Settings UI so users
  /// can pick up edits without restarting the app.
  func reloadAppConfig() {
    // Force `applyRuntimeOverridesIfNeeded` to rebuild and push a fresh
    // config to ghostty, regardless of whether our override contents changed.
    runtimeOverrideSignature = ""
    applyRuntimeOverridesIfNeeded()
  }

  func setConfigPath(_ path: String?) {
    let normalizedPath = Self.normalizedConfigPath(path)
    guard configPath != normalizedPath else { return }
    configPath = normalizedPath
    themeFallbackOverrideContents = ""
    reloadAppConfig()
    if let currentColorScheme {
      reconcileThemeFallback(for: currentColorScheme)
    }
  }

  func applyConfig(
    _ config: ghostty_config_t,
    target: ghostty_target_s,
    app: ghostty_app_t
  ) {
    switch target.tag {
    case GHOSTTY_TARGET_APP:
      ghostty_app_update_config(app, config)
    case GHOSTTY_TARGET_SURFACE:
      guard let surface = target.target.surface else { return }
      ghostty_surface_update_config(surface, config)
    default:
      return
    }
  }

  func applyColorSchemeToSurfaces(_ scheme: ghostty_color_scheme_e) {
    for ref in surfaceRefs where ref.isValid {
      ghostty_surface_set_color_scheme(ref.surface, scheme)
    }
  }

  func setConfig(_ config: ghostty_config_t) {
    if let existing = self.config {
      ghostty_config_free(existing)
    }
    self.config = config
  }

  func applyAppKeybindArguments(_ keybindArguments: [String]) {
    let entries = Self.keybindEntries(from: keybindArguments)
    let overrideEntries = Self.makeKeybindOverrideEntries(
      entries: entries,
      previousEntries: appKeybindOverrideEntries
    )
    let contents =
      overrideEntries
      .map { "keybind = \($0)" }
      .joined(separator: "\n")
    guard contents != appKeybindOverrideContents else { return }
    appKeybindOverrideEntries = entries
    appKeybindOverrideContents = contents
    applyRuntimeOverridesIfNeeded()
  }

  static func keybindEntries(from keybindArguments: [String]) -> [String] {
    let prefix = "--keybind="
    return keybindArguments.compactMap { argument in
      guard argument.hasPrefix(prefix) else { return nil }
      return String(argument.dropFirst(prefix.count))
    }
  }

  static func makeKeybindOverrideEntries(
    entries: [String],
    previousEntries: [String]
  ) -> [String] {
    var unbindEntries: [String] = []
    var seenTriggers = Set<String>()
    for entry in previousEntries + entries {
      guard let trigger = keybindTrigger(from: entry), seenTriggers.insert(trigger).inserted else {
        continue
      }
      unbindEntries.append("\(trigger)=unbind")
    }
    return unbindEntries + entries
  }

  static func keybindTrigger(from entry: String) -> String? {
    guard let separator = entry.firstIndex(of: "=") else { return nil }
    let trigger = String(entry[..<separator])
    return trigger.isEmpty ? nil : trigger
  }

  nonisolated static func normalizedConfigPath(_ path: String?) -> String? {
    let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.flatMap { $0.isEmpty ? nil : $0 }
  }

  static func loadConfig(at path: String?, additionalFiles: [URL] = []) -> ghostty_config_t? {
    guard let config = ghostty_config_new() else { return nil }
    if let path {
      path.withCString { ghostty_config_load_file(config, $0) }
    } else {
      ghostty_config_load_default_files(config)
    }
    ghostty_config_load_recursive_files(config)
    ghostty_config_load_cli_args(config)
    loadTerminalProgramOverrides(into: config)
    for url in additionalFiles {
      url.path.withCString { ghostty_config_load_file(config, $0) }
    }
    ghostty_config_finalize(config)
    return config
  }

  /// Reports Prowl in `TERM_PROGRAM` so programs detect the real host terminal;
  /// loaded after the user config so it wins. The version is always emitted
  /// because Ghostty's `env` map can override a key but not clear its seeded
  /// value, so a blank value falls back to a placeholder.
  nonisolated static func terminalProgramOverrides(version: String?) -> String {
    // Trim like Ghostty's `env` parser, which strips whitespace then drops a
    // now-empty value, leaving its seeded version.
    let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
    return """
      env = TERM_PROGRAM=prowl
      env = TERM_PROGRAM_VERSION=\(resolved)
      """
  }

  nonisolated private static var appVersion: String? {
    let info = Bundle.main.infoDictionary
    let candidates = [info?["CFBundleShortVersionString"], info?["CFBundleVersion"]]
    return candidates.lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
  }

  nonisolated static func loadTerminalProgramOverrides(into config: ghostty_config_t) {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("prowl-ghostty-term-program.conf")
    do {
      try terminalProgramOverrides(version: appVersion).write(
        to: url, atomically: true, encoding: .utf8)
    } catch {
      ghosttyLogger.warning(
        "Failed to write TERM_PROGRAM override file: \(error.localizedDescription)")
      return
    }
    url.path.withCString { path in
      ghostty_config_load_file(config, path)
    }
  }

  func keyboardShortcut(for action: String) -> KeyboardShortcut? {
    guard let config else { return nil }
    let trigger = ghostty_config_trigger(config, action, UInt(action.lengthOfBytes(using: .utf8)))
    return Self.keyboardShortcut(for: trigger)
  }

  func defaultFontSize() -> Float32 {
    guard let config else { return 0 }
    var value: Double = 0
    let key = "font-size"
    guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
      return 0
    }
    return Float32(value)
  }

  func commandPaletteEntries() -> [GhosttyCommand] {
    guard let config else { return [] }
    var value = ghostty_config_command_list_s()
    let key = "command-palette-entry"
    guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
      return []
    }
    guard value.len > 0, let commands = value.commands else { return [] }
    let buffer = UnsafeBufferPointer(start: commands, count: Int(value.len))
    return buffer.map(GhosttyCommand.init(cValue:))
  }

  func focusFollowsMouse() -> Bool {
    guard let config else { return false }
    var value = false
    let key = "focus-follows-mouse"
    _ = ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
    return value
  }

  func shouldShowScrollbar() -> Bool {
    guard let config else { return true }
    var valuePtr: UnsafePointer<CChar>?
    let key = "scrollbar"
    if ghostty_config_get(config, &valuePtr, key, UInt(key.lengthOfBytes(using: .utf8))),
      let ptr = valuePtr
    {
      return String(cString: ptr) != "never"
    }
    return true
  }

  func backgroundOpacity() -> Double {
    guard let config else { return 1 }
    var value: Double = 1
    let key = "background-opacity"
    _ = ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
    return min(max(value, 0.001), 1)
  }

  func unfocusedSplitOverlayOpacity() -> Double {
    guard let config else { return 0 }
    var value: Double = 0.85
    let key = "unfocused-split-opacity"
    _ = ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
    return min(max(1 - value, 0), 1)
  }

  func unfocusedSplitFill() -> Color? {
    guard let config else { return nil }
    var color = ghostty_config_color_s()
    let fillKey = "unfocused-split-fill"
    if ghostty_config_get(config, &color, fillKey, UInt(fillKey.lengthOfBytes(using: .utf8))) {
      return Color(nsColor: NSColor(ghostty: color))
    }
    let backgroundKey = "background"
    if ghostty_config_get(
      config, &color, backgroundKey, UInt(backgroundKey.lengthOfBytes(using: .utf8)))
    {
      return Color(nsColor: NSColor(ghostty: color))
    }
    ghosttyLogger.warning(
      "Ghostty config missing both 'unfocused-split-fill' and 'background'; skipping unfocused split overlay."
    )
    return nil
  }

  func splitDividerColor() -> Color? {
    guard let config else { return nil }
    var color = ghostty_config_color_s()
    let key = "split-divider-color"
    guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else {
      return nil
    }
    return Color(nsColor: NSColor(ghostty: color))
  }

  /// Reads a Prowl-specific override for the visible divider thickness from the
  /// primary Ghostty config file (the one returned by `ghostty_config_open_path`).
  /// Ghostty itself has no such option (and its own divider size is hardcoded),
  /// so we layer a `prowl-split-divider-width = N` directive on top of the
  /// user's existing Ghostty config to avoid carrying another fork patch.
  func splitDividerWidth() -> CGFloat? {
    Self.parseProwlSplitDividerWidth(at: Self.ghosttyConfigPath())
  }

  nonisolated static func ghosttyConfigPath() -> String? {
    let configStr = ghostty_config_open_path()
    defer { ghostty_string_free(configStr) }
    guard let ptr = configStr.ptr, configStr.len > 0 else { return nil }
    let path = String(data: Data(bytes: ptr, count: Int(configStr.len)), encoding: .utf8)
    guard let path, !path.isEmpty else { return nil }
    return path
  }

  nonisolated static func parseProwlSplitDividerWidth(at path: String?) -> CGFloat? {
    guard let path else { return nil }
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return parseProwlSplitDividerWidth(from: contents)
  }

  nonisolated static func parseProwlSplitDividerWidth(from contents: String) -> CGFloat? {
    let key = "prowl-split-divider-width"
    var resolved: CGFloat?
    for rawLine in contents.split(whereSeparator: \.isNewline) {
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
      guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
      let lhs = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
      guard lhs == key else { continue }
      let rhs = trimmed[trimmed.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
      guard let value = Double(rhs) else { continue }
      // Clamp to a sane visible range — 0 disables the visible bar while
      // keeping the invisible hit area, large values are capped to prevent
      // accidental absurdities from a typo.
      resolved = CGFloat(min(max(value, 0), 32))
    }
    return resolved
  }

  func backgroundColor() -> NSColor {
    backgroundColorFromConfig() ?? NSColor.windowBackgroundColor
  }

  func scrollbarAppearanceName() -> NSAppearance.Name {
    backgroundColor().ghosttyIsLightColor ? .aqua : .darkAqua
  }

  /// Returns a window background color that tints the macOS glass effect
  /// for non-opaque windows. macOS 26 renders a white-biased glass on
  /// non-opaque windows; darker colors need higher alpha to counteract
  /// the white bias, lighter colors need almost none.
  static func chromeBackgroundColor(for color: NSColor) -> NSColor {
    color.withAlphaComponent(0.7)
  }

  func backgroundColorFromConfig() -> NSColor? {
    guard let config else { return nil }
    var color: ghostty_config_color_s = .init()
    let key = "background"
    if !ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) {
      return nil
    }
    return NSColor(ghostty: color)
  }

  static func keyboardShortcut(for trigger: ghostty_input_trigger_s) -> KeyboardShortcut? {
    let key: KeyEquivalent
    switch trigger.tag {
    case GHOSTTY_TRIGGER_PHYSICAL:
      guard let equiv = keyToEquivalent[trigger.key.physical] else { return nil }
      key = equiv
    case GHOSTTY_TRIGGER_UNICODE:
      guard let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
      key = KeyEquivalent(Character(scalar))
    case GHOSTTY_TRIGGER_CATCH_ALL:
      return nil
    default:
      return nil
    }
    return KeyboardShortcut(key, modifiers: eventModifiers(mods: trigger.mods))
  }

  static func eventModifiers(mods: ghostty_input_mods_e) -> EventModifiers {
    var flags: EventModifiers = []
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
  }

  static let keyToEquivalent: [ghostty_input_key_e: KeyEquivalent] = [
    GHOSTTY_KEY_ARROW_UP: .upArrow,
    GHOSTTY_KEY_ARROW_DOWN: .downArrow,
    GHOSTTY_KEY_ARROW_LEFT: .leftArrow,
    GHOSTTY_KEY_ARROW_RIGHT: .rightArrow,
    GHOSTTY_KEY_HOME: .home,
    GHOSTTY_KEY_END: .end,
    GHOSTTY_KEY_DELETE: .delete,
    GHOSTTY_KEY_PAGE_UP: .pageUp,
    GHOSTTY_KEY_PAGE_DOWN: .pageDown,
    GHOSTTY_KEY_ESCAPE: .escape,
    GHOSTTY_KEY_ENTER: .return,
    GHOSTTY_KEY_TAB: .tab,
    GHOSTTY_KEY_BACKSPACE: .delete,
    GHOSTTY_KEY_SPACE: .space,
  ]
}
