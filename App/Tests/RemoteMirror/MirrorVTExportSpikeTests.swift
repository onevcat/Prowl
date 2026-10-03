import AppKit
import Foundation
import GhosttyKit
import Testing

/// Opt-in experiment only. Uses its own Ghostty app and clipboard callback;
/// production runtime, Mirror transport, and mobile clients are not involved.
@Suite(.serialized)
@MainActor
struct MirrorVTExportSpikeTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["PROWL_VT_EXPORT_SPIKE"] == "1"),
    .timeLimit(.minutes(3)))
  func styledHistoryReplay() async throws {
    let directory = URL(filePath: "/tmp/prowl-vt-export-spike")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let rowCount = Int(ProcessInfo.processInfo.environment["PROWL_VT_EXPORT_ROWS"] ?? "500") ?? 500
    try #require(rowCount > 50)
    let contents =
      (1...rowCount).map { row in
        "\u{1B}[38;2;80;190;240mROW \(row)\u{1B}[0m  "
          + "\u{1B}[1;33m粗体 Bold\u{1B}[0m │ 界🙂 │ "
          + "\u{1B}[48;2;80;40;100m背景 Background\u{1B}[0m "
          + (row.isMultiple(of: 7) ? String(repeating: "长行 wrap 界🙂 ", count: 12) : "table │ value")
          + "\r\n"
      }.joined() + "END-OF-FIXTURE"
    try Data(contents.utf8).write(to: directory.appending(path: "source.vt"))
    let host = try Terminal(
      directory: directory, file: "source.vt", title: "Host — native scrollback")
    defer { host.close() }
    try await wait { host.text().contains("END-OF-FIXTURE") }
    let beforeClipboard = NSPasteboard.general.changeCount
    let start = ContinuousClock.now
    let archive = try host.export()
    let elapsed = start.duration(to: .now)
    #expect(NSPasteboard.general.changeCount == beforeClipboard)
    #expect(try #require(String(data: archive, encoding: .utf8)).contains("38;2;80;190;240"))
    try archive.write(to: directory.appending(path: "replay.vt"))
    let replay = try Terminal(
      directory: directory, file: "replay.vt", title: "Replica — exported VT replay")
    defer { replay.close() }
    try await wait { replay.text().contains("END-OF-FIXTURE") }
    #expect(host.size.rows == replay.size.rows)
    #expect(host.size.columns == replay.size.columns)
    host.action("scroll_page_lines:-50")
    replay.action("scroll_page_lines:-50")
    try await wait {
      !host.text().contains("END-OF-FIXTURE") && !replay.text().contains("END-OF-FIXTURE")
    }
    let original = host.text()
    let reconstructed = replay.text()
    try original.write(to: directory.appending(path: "host.txt"), atomically: true, encoding: .utf8)
    try reconstructed.write(
      to: directory.appending(path: "replica.txt"), atomically: true, encoding: .utf8)
    let reexport = try replay.export()
    #expect(try #require(String(data: reexport, encoding: .utf8)).contains("38;2;80;190;240"))
    #expect(try #require(String(data: reexport, encoding: .utf8)).contains("48;2;80;40;100"))
    #expect(original == reconstructed)
    try host.export(format: "html").write(to: directory.appending(path: "host.html"))
    try replay.export(format: "html").write(to: directory.appending(path: "replica.html"))
    let report =
      "fixtureRows=\(rowCount) rows=\(host.size.rows) columns=\(host.size.columns) "
      + "bytes=\(archive.count) exportTime=\(elapsed) textEqual=\(original == reconstructed) "
      + "clipboardUnchanged=\(NSPasteboard.general.changeCount == beforeClipboard)\n"
    try report.write(to: directory.appending(path: "result.txt"), atomically: true, encoding: .utf8)
    host.window.setFrameOrigin(NSPoint(x: 30, y: 120))
    replay.window.setFrameOrigin(NSPoint(x: 770, y: 120))
    host.window.orderFront(nil)
    replay.window.orderFront(nil)
    // A short opt-in inspection window permits screenshots via the UI tool.
    try await wait(timeout: .seconds(150)) {
      ProcessInfo.processInfo.environment["PROWL_VT_EXPORT_INSPECT"] != "1"
        || FileManager.default.fileExists(atPath: directory.appending(path: "finish").path)
    }
  }

  private final class Clipboard {
    var path: String?
  }

  private final class Terminal {
    let window: NSWindow
    let view: NSView
    let clipboard = Clipboard()
    let config: ghostty_config_t
    let app: ghostty_app_t
    let surface: ghostty_surface_t
    var timer: Timer?
    var size: ghostty_surface_size_s { ghostty_surface_size(surface) }

    init(directory: URL, file: String, title: String) throws {
      config = try #require(ghostty_config_new())
      let configuration = directory.appending(path: "ghostty.conf")
      try "font-size = 12\nbackground = #20242c\nforeground = #e0e0e0\nscrollback-limit = 10000000\n"
        .write(
          to: configuration, atomically: true, encoding: .utf8)
      ghostty_config_load_file(config, configuration.path)
      ghostty_config_finalize(config)
      var runtime = ghostty_runtime_config_s(
        userdata: nil, supports_selection_clipboard: false,
        wakeup_cb: { @Sendable _ in }, action_cb: { @Sendable _, _, _ in false },
        read_clipboard_cb: { @Sendable _, _, _ in false },
        confirm_read_clipboard_cb: { @Sendable _, _, _, _ in },
        write_clipboard_cb: { @Sendable userdata, _, content, length, _ in
          guard let userdata, let content, length == 1, let data = content.pointee.data else {
            return
          }
          let path = String(cString: data)
          let pointer = UInt(bitPattern: userdata)
          MainActor.assumeIsolated {
            Unmanaged<Clipboard>.fromOpaque(UnsafeMutableRawPointer(bitPattern: pointer)!)
              .takeUnretainedValue().path = path
          }
        }, close_surface_cb: { @Sendable _, _ in })
      app = try #require(ghostty_app_new(&runtime, config))
      view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
      view.wantsLayer = true
      window = NSWindow(
        contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = title
      window.contentView = view
      var settings = ghostty_surface_config_new()
      settings.platform_tag = GHOSTTY_PLATFORM_MACOS
      settings.platform = ghostty_platform_u(
        macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
      settings.userdata = Unmanaged.passUnretained(clipboard).toOpaque()
      settings.scale_factor = window.backingScaleFactor
      let script = directory.appending(path: file + ".sh")
      try
        "#!/bin/bash\nstty -echo\ncat '\(directory.appending(path: file).path)'\nwhile IFS= read -r line; do :; done\n"
        .write(
          to: script, atomically: true, encoding: .utf8)
      let command = strdup("/bin/bash '\(script.path)'")!
      defer { free(command) }
      settings.command = UnsafePointer(command)
      surface = try #require(ghostty_surface_new(app, &settings))
      ghostty_surface_set_content_scale(
        surface, window.backingScaleFactor, window.backingScaleFactor)
      ghostty_surface_set_size(
        surface, UInt32(720 * window.backingScaleFactor), UInt32(520 * window.backingScaleFactor))
      let appBits = UInt(bitPattern: app)
      timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
        ghostty_app_tick(UnsafeMutableRawPointer(bitPattern: appBits))
      }
    }

    func action(_ value: String) {
      _ = ghostty_surface_binding_action(surface, value, UInt(value.utf8.count))
    }

    func text() -> String {
      var result = ghostty_text_s()
      let selection = ghostty_selection_s(
        top_left: .init(
          tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
        bottom_right: .init(
          tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
        rectangle: false)
      guard ghostty_surface_read_text(surface, selection, &result) else { return "" }
      defer { ghostty_surface_free_text(surface, &result) }
      guard let bytes = result.text else { return "" }
      return String(
        bytes: UnsafeBufferPointer(
          start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
          count: Int(result.text_len)), encoding: .utf8) ?? ""
    }

    func export(format: String = "vt") throws -> Data {
      clipboard.path = nil
      let binding = "write_screen_file:copy,\(format)"
      try #require(ghostty_surface_binding_action(surface, binding, UInt(binding.utf8.count)))
      let file = URL(filePath: try #require(clipboard.path))
      let data = try Data(contentsOf: file)
      try FileManager.default.removeItem(at: file)
      return data
    }

    func close() {
      timer?.invalidate()
      ghostty_surface_free(surface)
      ghostty_app_free(app)
      ghostty_config_free(config)
      window.close()
    }
  }

  private func wait(timeout: Duration = .seconds(15), until condition: @MainActor () throws -> Bool)
    async throws
  {
    let (ticks, continuation) = AsyncStream<Void>.makeStream()
    let timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in
      continuation.yield(())
    }
    defer {
      timer.invalidate()
      continuation.finish()
    }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    for await _ in ticks {
      if try condition() { return }
      if ContinuousClock.now >= deadline { throw NSError(domain: "VTExportSpikeTimeout", code: 1) }
    }
    throw CancellationError()
  }
}
