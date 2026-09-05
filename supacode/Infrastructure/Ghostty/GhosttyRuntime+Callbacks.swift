import AppKit
import GhosttyKit

extension GhosttyRuntime {
  static func runtime(from userdata: UnsafeMutableRawPointer?) -> GhosttyRuntime? {
    guard let userdata else { return nil }
    return Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
  }

  static func runtime(fromApp app: ghostty_app_t) -> GhosttyRuntime? {
    guard let userdata = ghostty_app_userdata(app) else { return nil }
    return runtime(from: userdata)
  }

  static func surfaceBridge(fromUserdata userdata: UnsafeMutableRawPointer?)
    -> GhosttySurfaceBridge?
  {
    guard let userdata else { return nil }
    return Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
  }

  static func surfaceBridge(fromSurface surface: ghostty_surface_t?)
    -> GhosttySurfaceBridge?
  {
    guard let surface, let userdata = ghostty_surface_userdata(surface) else { return nil }
    return Unmanaged<GhosttySurfaceBridge>.fromOpaque(userdata).takeUnretainedValue()
  }

  nonisolated static func wakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    let userdataBits = userdata.map { UInt(bitPattern: $0) }
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        wakeup(userdataBits: userdataBits)
      }
      return
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        wakeup(userdataBits: userdataBits)
      }
    }
  }

  nonisolated static func actionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
  ) -> Bool {
    guard let app else { return false }
    let appBits = UInt(bitPattern: app)
    if Thread.isMainThread {
      return MainActor.assumeIsolated {
        handleAction(appBits: appBits, target: target, action: action)
      }
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        _ = handleAction(appBits: appBits, target: target, action: action)
      }
    }
    return false
  }

  nonisolated static func readClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
  ) -> Bool {
    let userdataBits = userdata.map { UInt(bitPattern: $0) }
    let stateBits = state.map { UInt(bitPattern: $0) }
    if Thread.isMainThread {
      return MainActor.assumeIsolated {
        readClipboard(userdataBits: userdataBits, location: location, stateBits: stateBits)
      }
    }
    return DispatchQueue.main.sync {
      MainActor.assumeIsolated {
        readClipboard(userdataBits: userdataBits, location: location, stateBits: stateBits)
      }
    }
  }

  nonisolated static func confirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
  ) {
    guard let string else { return }
    let value = String(cString: string)
    let userdataBits = userdata.map { UInt(bitPattern: $0) }
    let stateBits = state.map { UInt(bitPattern: $0) }
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        confirmReadClipboard(
          userdataBits: userdataBits,
          value: value,
          stateBits: stateBits,
          request: request
        )
      }
      return
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        confirmReadClipboard(
          userdataBits: userdataBits,
          value: value,
          stateBits: stateBits,
          request: request
        )
      }
    }
  }

  nonisolated static func writeClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
  ) {
    _ = userdata
    guard let content, len > 0 else { return }
    let items: [(mime: String, data: String)] = (0..<len).compactMap { index in
      let item = content.advanced(by: index).pointee
      guard let mimePtr = item.mime, let dataPtr = item.data else { return nil }
      return (mime: String(cString: mimePtr), data: String(cString: dataPtr))
    }
    guard !items.isEmpty else { return }
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        writeClipboard(
          location: location,
          items: items,
          confirm: confirm
        )
      }
      return
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        writeClipboard(
          location: location,
          items: items,
          confirm: confirm
        )
      }
    }
  }

  nonisolated static func closeSurfaceCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
  ) {
    let userdataBits = userdata.map { UInt(bitPattern: $0) }
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        closeSurface(userdataBits: userdataBits, processAlive: processAlive)
      }
      return
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        closeSurface(userdataBits: userdataBits, processAlive: processAlive)
      }
    }
  }

  static func wakeup(userdataBits: UInt?) {
    let userdata = userdataBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    guard let runtime = runtime(from: userdata) else { return }
    runtime.tick()
  }

  static func handleAction(
    appBits: UInt,
    target: ghostty_target_s,
    action: ghostty_action_s
  ) -> Bool {
    guard let app = ghostty_app_t(bitPattern: appBits) else { return false }
    if let runtime = runtime(fromApp: app) {
      if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE, target.tag == GHOSTTY_TARGET_APP {
        let config = action.action.config_change.config
        guard let clone = ghostty_config_clone(config) else { return false }
        runtime.setConfig(clone)
        if let scheme = runtime.currentColorScheme {
          runtime.reconcileThemeFallback(for: scheme)
        }
        runtime.onConfigChange?()
        NotificationCenter.default.post(name: .ghosttyRuntimeConfigDidChange, object: runtime)
      }
      if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
        let soft = action.action.reload_config.soft
        runtime.reloadConfig(soft: soft, target: target)
      }
    }
    if action.tag == GHOSTTY_ACTION_OPEN_CONFIG, target.tag == GHOSTTY_TARGET_APP {
      openGhosttyConfig()
      return true
    }
    if action.tag == GHOSTTY_ACTION_QUIT {
      if let runtime = runtime(fromApp: app) {
        runtime.onQuit?()
      }
      return true
    }
    if action.tag == GHOSTTY_ACTION_CLOSE_WINDOW {
      closeWindow(target: target)
      return true
    }
    guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
    guard let surface = target.target.surface else { return false }
    guard let bridge = surfaceBridge(fromSurface: surface) else { return false }
    return bridge.handleAction(target: target, action: action)
  }

  static func closeWindow(target: ghostty_target_s) {
    switch target.tag {
    case GHOSTTY_TARGET_SURFACE:
      guard let surface = target.target.surface else { return }
      guard let bridge = surfaceBridge(fromSurface: surface) else { return }
      bridge.surfaceView?.window?.close()
    default:
      break
    }
  }

  static func openGhosttyConfig() {
    let configStr = ghostty_config_open_path()
    defer { ghostty_string_free(configStr) }
    guard let ptr = configStr.ptr else { return }
    let path = String(data: Data(bytes: ptr, count: Int(configStr.len)), encoding: .utf8) ?? ""
    guard !path.isEmpty else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-t", path]
    try? process.run()
  }

  static func readClipboard(
    userdataBits: UInt?,
    location: ghostty_clipboard_e,
    stateBits: UInt?
  ) -> Bool {
    let userdata = userdataBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    let state = stateBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    guard let bridge = surfaceBridge(fromUserdata: userdata), let surface = bridge.surface else {
      return false
    }
    guard let value = NSPasteboard.ghostty(location)?.getOpinionatedStringContents() else {
      return false
    }
    if !value.isEmpty { bridge.surfaceView?.recordEditingActivity() }
    value.withCString { ptr in
      ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
    }
    return true
  }

  static func confirmReadClipboard(
    userdataBits: UInt?,
    value: String,
    stateBits: UInt?,
    request: ghostty_clipboard_request_e
  ) {
    _ = request
    let userdata = userdataBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    let state = stateBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    guard let bridge = surfaceBridge(fromUserdata: userdata), let surface = bridge.surface else {
      return
    }
    if !value.isEmpty { bridge.surfaceView?.recordEditingActivity() }
    value.withCString { ptr in
      ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
    }
  }

  static func writeClipboard(
    location: ghostty_clipboard_e,
    items: [(mime: String, data: String)],
    confirm: Bool
  ) {
    _ = confirm

    guard let pasteboard = NSPasteboard.ghostty(location) else { return }
    let types = items.compactMap { NSPasteboard.PasteboardType(mimeType: $0.mime) }
    pasteboard.declareTypes(types, owner: nil)
    for item in items {
      guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
      pasteboard.setString(item.data, forType: type)
    }
  }

  static func closeSurface(userdataBits: UInt?, processAlive: Bool) {
    let userdata = userdataBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    guard let bridge = surfaceBridge(fromUserdata: userdata) else { return }
    bridge.closeSurface(processAlive: processAlive)
  }
}
