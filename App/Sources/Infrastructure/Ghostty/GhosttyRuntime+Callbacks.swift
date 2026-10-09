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
    _ state: UnsafeMutableRawPointer?,
    _ mimes: UnsafeBufferPointer<UnsafePointer<CChar>?>,
    _ list: Bool
  ) -> ghostty_clipboard_read_result_e {
    // The MIME list is borrowed for the duration of the call: copy it before
    // leaving the calling thread.
    let requested = mimes.compactMap { pointer in pointer.map { String(cString: $0) } }
    let userdataBits = userdata.map { UInt(bitPattern: $0) }
    let stateBits = state.map { UInt(bitPattern: $0) }
    if Thread.isMainThread {
      return MainActor.assumeIsolated {
        readClipboard(
          userdataBits: userdataBits,
          location: location,
          stateBits: stateBits,
          mimes: requested,
          list: list
        )
      }
    }
    return DispatchQueue.main.sync {
      MainActor.assumeIsolated {
        readClipboard(
          userdataBits: userdataBits,
          location: location,
          stateBits: stateBits,
          mimes: requested,
          list: list
        )
      }
    }
  }

  nonisolated static func confirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
  ) {
    // The confirmation payload is borrowed from libghostty: copy it before
    // leaving the calling thread.
    let payload = confirm.map { GhosttyClipboardPayload(confirm: $0.pointee) }
    let userdataBits = userdata.map { UInt(bitPattern: $0) }
    let stateBits = state.map { UInt(bitPattern: $0) }
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        confirmReadClipboard(
          userdataBits: userdataBits,
          payload: payload,
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
          payload: payload,
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
    guard let content, len > 0 else { return }
    let items: [(mime: String, data: String)] = (0..<len).compactMap { index in
      let item = content.advanced(by: index).pointee
      guard let mimePtr = item.mime, let dataPtr = item.data else { return nil }
      // `len` bounds the payload; the bytes are not necessarily NUL-terminated.
      let bytes = UnsafeRawBufferPointer(start: dataPtr, count: item.len)
      guard let data = String(bytes: bytes, encoding: .utf8) else { return nil }
      return (mime: String(cString: mimePtr), data: data)
    }
    guard !items.isEmpty else { return }
    let exportUserdataBits = userdata.map { UInt(bitPattern: $0) }
    if Thread.isMainThread {
      let consumed = MainActor.assumeIsolated {
        guard
          let capture = surfaceBridge(
            fromUserdata: exportUserdataBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) })?
            .captureClipboard
        else { return false }
        capture(items)
        return true
      }
      if consumed { return }
    }
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
    if target.tag == GHOSTTY_TARGET_APP, let runtime = runtime(fromApp: app),
      let handled = runtime.handleAppScopedAction(action.tag)
    {
      return handled
    }
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
      openGhosttyConfig(source: runtime(fromApp: app)?.configSource ?? .ghosttyDefault)
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

  /// Opens the config file of `source` in the default text editor. Like Ghostty,
  /// it creates an empty file first when none exists.
  static func openGhosttyConfig(source: GhosttyConfigSource) {
    guard let path = source.editableFilePath, !path.isEmpty else { return }
    if !FileManager.default.fileExists(atPath: path) {
      let created = FileManager.default.createFile(atPath: path, contents: nil)
      guard created else {
        ghosttyLogger.warning("Failed to create Ghostty config file: \(path)")
        return
      }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-t", path]
    try? process.run()
  }

  /// Serves a clipboard read (paste, OSC 52, Kitty clipboard): the requested
  /// MIME representations are read from the pasteboard and handed back through
  /// `ghostty_surface_complete_clipboard_request`. `list` asks for the declared
  /// MIME types without data (Kitty list requests, mode 5522 paste events).
  static func readClipboard(
    userdataBits: UInt?,
    location: ghostty_clipboard_e,
    stateBits: UInt?,
    mimes: [String],
    list: Bool
  ) -> ghostty_clipboard_read_result_e {
    let userdata = userdataBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    let state = stateBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    guard let bridge = surfaceBridge(fromUserdata: userdata), let surface = bridge.surface else {
      return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
    }
    guard let pasteboard = NSPasteboard.ghostty(location) else {
      return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
    }
    let payload = GhosttyClipboardPayload(pasteboard: pasteboard, mimes: mimes, list: list)
    if payload.contents.isEmpty, !list {
      return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
    }
    if payload.hasText { bridge.surfaceView?.recordEditingActivity() }
    completeClipboardRequest(surface, payload: payload, state: state)
    return GHOSTTY_CLIPBOARD_READ_STARTED
  }

  /// Prowl approves every clipboard read that libghostty asks to confirm
  /// (unsafe paste, OSC 52 and Kitty reads) without a dialog, as it did before
  /// the Kitty clipboard protocol. The payload libghostty handed over is
  /// completed as confirmed, so the pasteboard is never read a second time.
  static func confirmReadClipboard(
    userdataBits: UInt?,
    payload: GhosttyClipboardPayload?,
    stateBits: UInt?,
    request: ghostty_clipboard_request_e
  ) {
    _ = request
    let userdata = userdataBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    let state = stateBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
    guard let bridge = surfaceBridge(fromUserdata: userdata), let surface = bridge.surface else {
      return
    }
    guard let payload else {
      ghostty_surface_deny_clipboard_request(surface, state)
      return
    }
    if payload.hasText { bridge.surfaceView?.recordEditingActivity() }
    completeClipboardRequest(surface, payload: payload, state: state, confirmed: true)
  }

  /// Marshals `payload` into C memory for the duration of
  /// `ghostty_surface_complete_clipboard_request`; libghostty copies what it
  /// needs before returning.
  static func completeClipboardRequest(
    _ surface: ghostty_surface_t,
    payload: GhosttyClipboardPayload,
    state: UnsafeMutableRawPointer?,
    confirmed: Bool = false
  ) {
    var cStrings: [UnsafeMutablePointer<CChar>] = []
    var cBuffers: [UnsafeMutableRawPointer] = []
    defer {
      for string in cStrings { free(string) }
      for buffer in cBuffers { buffer.deallocate() }
    }

    var cContents: [ghostty_clipboard_content_s] = []
    for entry in payload.contents {
      guard let mime = strdup(entry.mime) else { continue }
      cStrings.append(mime)
      let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(entry.data.count, 1), alignment: 1)
      cBuffers.append(buffer)
      entry.data.withUnsafeBytes { source in
        if let base = source.baseAddress {
          buffer.copyMemory(from: base, byteCount: source.count)
        }
      }
      cContents.append(
        ghostty_clipboard_content_s(
          mime: mime,
          data: buffer.assumingMemoryBound(to: CChar.self),
          len: entry.data.count
        )
      )
    }

    var cAvailable: [UnsafePointer<CChar>?] = []
    for mime in payload.available {
      guard let string = strdup(mime) else { continue }
      cStrings.append(string)
      cAvailable.append(UnsafePointer(string))
    }

    cContents.withUnsafeBufferPointer { contents in
      cAvailable.withUnsafeBufferPointer { available in
        var complete = ghostty_clipboard_complete_s(
          contents: contents.baseAddress,
          contents_len: contents.count,
          available: available.baseAddress,
          available_len: available.count,
          confirmed: confirmed,
          remember: false
        )
        ghostty_surface_complete_clipboard_request(surface, &complete, state)
      }
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
