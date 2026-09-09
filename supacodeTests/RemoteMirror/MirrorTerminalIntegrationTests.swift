import AppKit
import Darwin
import GhosttyKit
import Observation
import Testing

@testable import supacode

@MainActor
struct MirrorTerminalIntegrationTests {
  @Test(.timeLimit(.minutes(2))) func realTerminalRoundTripAndLifecycle() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    let descriptor = try #require(fixture.source.panes().first)
    #expect(descriptor.projectName == fixture.directory.lastPathComponent)
    #expect(descriptor.subtitle == "Mirror integration · Mirror integration")
    #expect(!descriptor.title.contains(fixture.hostView.id.uuidString.prefix(8)))
    fixture.host.start()
    try await fixture.wait("Host listener") { fixture.host.isRunning || fixture.host.error != nil }
    #expect(fixture.host.error == nil)
    let client = try await fixture.connect()
    try await fixture.waitForMirror(client, containing: "READY")

    try await verifyOutputAndInput(fixture, client: client)
    try await verifyViewport(fixture, client: client)
    try await verifyRawBytes(fixture, client: client)
    try await verifyHistory(fixture, client: client)
    try await verifyExclusiveSubscription(fixture)

    client.close()
    try await fixture.wait("unsubscribe") { fixture.host.subscriberCount == 0 }
    try fixture.send("after-close")
    try await fixture.wait("Host survives mirror close") { fixture.hostText.contains("INPUT:after-close") }
    let reconnected = try await fixture.connect()
    try await fixture.waitForMirror(reconnected, containing: "INPUT:after-close")
    fixture.host.stop()
    try await fixture.wait("Client sees Host stop") { !reconnected.isConnected }
    #expect(reconnected.error != nil)
    #expect(reconnected.replica.view == nil)
    try fixture.send("after-stop")
    try await fixture.wait("Host survives server stop") { fixture.hostText.contains("INPUT:after-stop") }
  }

  private func verifyOutputAndInput(_ fixture: Fixture, client: MirrorClient) async throws {
    try fixture.send("think")
    try await fixture.waitForMirror(client, containing: "THINKING:思考中")
    try fixture.send("finish")
    try await fixture.waitForMirror(client, containing: "FINAL:结论")
    #expect(!fixture.replicaText(client).contains("THINKING"))
    let replica = try #require(client.replica.view)
    replica.insertText("client中文", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(replica.sendCLIKeyToken("enter"))
    try await fixture.waitForMirror(client, containing: "INPUT:client中文")
    fixture.hostView.insertText("local", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(fixture.hostView.sendCLIKeyToken("enter"))
    try await fixture.waitForMirror(client, containing: "INPUT:local")
    let original = try fixture.source.snapshot(fixture.hostView.id)
    replica.setFrameSize(NSSize(width: 320, height: 240))
    replica.updateSurfaceSize()
    #expect(try fixture.source.snapshot(fixture.hostView.id) == original)
    #expect(try fixture.frame(replica) == original)
    fixture.hostView.setFrameSize(NSSize(width: 720, height: 480))
    fixture.hostView.updateSurfaceSize()
    try fixture.send("resized")
    try await fixture.waitForMirror(client, containing: "INPUT:resized")
  }

  private func verifyHistory(_ fixture: Fixture, client: MirrorClient) async throws {
    try fixture.send("history")
    try await fixture.waitForMirror(client, containing: "HISTORY:450")
    client.loadHistory(refresh: true)
    try await fixture.wait("history page") { !client.isLoadingHistory }
    #expect(client.historyLines.count == 200)
    #expect(client.historyLines.contains("HISTORY:450"))
    let latest = client.historyLines
    let offset = client.historyOffset
    #expect(offset > 0)
    try fixture.send("while-history")
    try await fixture.waitForMirror(client, containing: "INPUT:while-history")
    #expect(client.historyLines == latest)
    client.loadHistory()
    try await fixture.wait("older history") { !client.isLoadingHistory }
    #expect(client.historyOffset < offset)
    #expect(Array(client.historyLines.suffix(latest.count)) == latest)
  }

  private func verifyViewport(_ fixture: Fixture, client: MirrorClient) async throws {
    let replica = try #require(client.replica.view)
    let window = try #require(replica.window)
    let original = try fixture.frame(replica)
    let viewport = MirrorTerminalScrollView(surface: replica, displaySize: client.replica.displaySize)
    window.contentView = viewport
    viewport.setFrameSize(NSSize(width: 320, height: 240))
    viewport.layoutSubtreeIfNeeded()
    #expect(replica.frame.height > viewport.contentSize.height)
    #expect(viewport.contentView.bounds.minY == 0)
    let event = try #require(
      CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 80, wheel2: 0, wheel3: 0))
    replica.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    try await fixture.wait("mirror viewport scroll") { viewport.contentView.bounds.minY > 0 }
    #expect(try fixture.frame(replica) == original)
    #expect(try fixture.source.snapshot(fixture.hostView.id) == original)
    viewport.contentView.scroll(to: .zero)
    viewport.setFrameSize(NSSize(width: 280, height: 200))
    viewport.layoutSubtreeIfNeeded()
    #expect(viewport.contentView.bounds.minY == 0)
    #expect(try fixture.frame(replica) == original)
  }

  private func verifyRawBytes(_ fixture: Fixture, client: MirrorClient) async throws {
    try fixture.send("bytes")
    try await fixture.waitForMirror(client, containing: "BINARY_READY")
    // Deliberately split UTF-8 and include NUL, Ctrl-C, ESC, an invalid UTF-8
    // byte, a literal backslash, and newlines to catch accidental text conversion.
    let bytes: [UInt8] = [0x00, 0x03, 0x1B, 0xFF, 0xC3, 0xA9, 0x5C, 0x0D, 0x0A]
    for byte in bytes {
      try fixture.source.write(Data([byte]), to: fixture.hostView.id)
    }
    try await fixture.waitForMirror(client, containing: "00 03 1b ff c3 a9 5c 0d 0a")
    try fixture.send("keys")
    try await fixture.waitForMirror(client, containing: "KEYS_READY")
    let replica = try #require(client.replica.view)
    #expect(replica.sendCLIKeyToken("up"))
    #expect(replica.sendCLIKeyToken("ctrl-c"))
    try await fixture.waitForMirror(client, containing: "1b 5b 41 03")
    try fixture.send("paste")
    try await fixture.waitForMirror(client, containing: "PASTE_READY")
    replica.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await fixture.waitForMirror(client, containing: "PASTE_DONE")
    let normalized = fixture.hostText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    #expect(normalized.contains("1b 5b 32 30 30 7e e4 b8 ad e6 96 87 1b 5b 32 30 31 7e"))
  }

  private func verifyExclusiveSubscription(_ fixture: Fixture) async throws {
    let second = fixture.makeClient()
    second.connect()
    try await fixture.wait("second discovery") { !second.panes.isEmpty || second.error != nil }
    let pane = try #require(second.panes.first)
    #expect(pane.busy)
    second.subscribe(pane)
    try await fixture.wait("exclusive subscription rejection") { second.error != nil }
    #expect(second.error?.contains("PANE_BUSY") == true)
    #expect(fixture.host.subscriberCount == 1)
  }

  private struct Failure: Error { let reason: String }

  @MainActor
  private final class Fixture {
    let directory: URL
    let runtime: GhosttyRuntime
    let manager: WorktreeTerminalManager
    let hostView: GhosttySurfaceView
    let source: GhosttyMirrorPaneSource
    let host: MirrorHost
    let suite: String
    let defaults: UserDefaults
    let previousRuntime: GhosttyRuntime?
    var clients: [MirrorClient] = []
    var windows: [NSWindow] = []

    init() throws {
      directory = FileManager.default.temporaryDirectory.appending(path: "mirror-terminal-\(UUID())")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let script = directory.appending(path: "terminal.sh")
      try Self.program.write(to: script, atomically: true, encoding: .utf8)
      previousRuntime = GhosttyRuntime.shared
      runtime = GhosttyRuntime()
      manager = WorktreeTerminalManager(runtime: runtime)
      let state = manager.state(
        for: Worktree(
          id: directory.path, name: "Mirror integration", detail: "", workingDirectory: directory,
          repositoryRootURL: directory))
      hostView = GhosttySurfaceView(
        runtime: runtime, workingDirectory: directory, context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
        command: "/bin/bash '\(script.path.replacing("'", with: "'\\''"))'")
      state.surfaces[hostView.id] = hostView
      let tab = state.tabManager.createTab(title: "Mirror integration", icon: nil)
      state.trees[tab] = SplitTree<GhosttySurfaceView>(view: hostView)
      state.focusedSurfaceIdByTab[tab] = hostView.id
      source = GhosttyMirrorPaneSource(manager: manager)
      suite = "MirrorTerminalIntegration-\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      host = MirrorHost(source: source, defaults: defaults)
      host.address = "127.0.0.1"
      host.port = String(try Self.unusedPort())
      attach(hostView)
    }

    var hostText: String { hostView.readScreenContentsForCLI() ?? "" }

    func replicaText(_ client: MirrorClient) -> String { client.replica.view?.readScreenContentsForCLI() ?? "" }

    func attach(_ view: GhosttySurfaceView) {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = view
      windows.append(window)
      view.updateSurfaceSize()
    }

    func makeClient() -> MirrorClient {
      let client = MirrorClient(
        address: "127.0.0.1", port: UInt16(host.port)!, pairingKey: host.pairingKey,
        replica: MirrorReplica(runtime: runtime))
      clients.append(client)
      return client
    }

    func connect() async throws -> MirrorClient {
      let client = makeClient()
      client.connect()
      try await wait("pane discovery") { !client.panes.isEmpty || client.error != nil }
      let pane = try #require(client.panes.first)
      #expect(pane.id == hostView.id)
      #expect(pane.projectName == directory.lastPathComponent)
      #expect(pane.subtitle == "Mirror integration · Mirror integration")
      client.subscribe(pane)
      try await wait("replica creation") { client.replica.view != nil || client.error != nil }
      attach(try #require(client.replica.view))
      return client
    }

    func send(_ command: String) throws { try source.write(Data((command + "\n").utf8), to: hostView.id) }

    func frame(_ view: GhosttySurfaceView) throws -> MirrorFrame {
      let surface = try #require(view.surface)
      var text = ghostty_text_s()
      try #require(ghostty_surface_read_snapshot(surface, &text))
      defer { ghostty_surface_free_text(surface, &text) }
      let bytes = try #require(text.text)
      let size = ghostty_surface_size(surface)
      return MirrorFrame(
        columns: UInt32(size.columns), rows: UInt32(size.rows), bytes: Data(bytes: bytes, count: Int(text.text_len)))
    }

    func waitForMirror(_ client: MirrorClient, containing text: String) async throws {
      do {
        try await wait("mirrored \(text)") {
          if let error = client.error { throw Failure(reason: error) }
          guard self.hostText.contains(text), self.replicaText(client).contains(text),
            let replica = client.replica.view
          else { return false }
          return try self.source.snapshot(self.hostView.id) == self.frame(replica)
        }
      } catch {
        let host = try source.snapshot(hostView.id)
        let replica = try client.replica.view.map { try frame($0) }
        let hostTail = Data(host.bytes.suffix(192)).base64EncodedString()
        let replicaTail = replica.map { Data($0.bytes.suffix(192)).base64EncodedString() } ?? "none"
        throw Failure(
          reason: "\(error); host=\(host.columns)x\(host.rows):\(String(reflecting: hostText.prefix(300))); "
            + "replica=\(String(describing: replica?.columns))x\(String(describing: replica?.rows)):"
            + "\(String(reflecting: replicaText(client).prefix(300))); "
            + "hostVT=\(hostTail); replicaVT=\(replicaTail)"
        )
      }
    }

    func wait(_ label: String, until condition: @MainActor () throws -> Bool) async throws {
      let (ticks, continuation) = AsyncStream<Void>.makeStream()
      let timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in continuation.yield(()) }
      defer {
        timer.invalidate()
        continuation.finish()
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      for await _ in ticks {
        if try condition() { return }
        if ContinuousClock.now >= deadline { throw Failure(reason: "Timed out: \(label)") }
      }
      throw CancellationError()
    }

    func close() {
      for client in clients { client.close() }
      host.stop()
      hostView.closeSurface()
      for window in windows { window.close() }
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
      GhosttyRuntime.shared = previousRuntime
    }

    private static func unusedPort() throws -> UInt16 {
      let descriptor = socket(AF_INET, SOCK_STREAM, 0)
      try #require(descriptor >= 0)
      defer { Darwin.close(descriptor) }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let result = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          guard Darwin.bind(descriptor, $0, length) == 0 else { return Int32(-1) }
          return getsockname(descriptor, $0, &length)
        }
      }
      try #require(result == 0)
      return UInt16(bigEndian: address.sin_port)
    }

    private static let program = #"""
      stty -echo
      printf '\033[2J\033[HREADY'
      while :; do
        IFS= read -r action || continue
        case "$action" in
          think) printf '\033[2J\033[H\033[31mTHINKING:思考中\033[0m\033[4;7H';;
          finish) printf '\033[2J\033[H\033[32mFINAL:结论\033[0m\033[2;3H';;
          history) for ((n=1; n<=450; n++)); do printf 'HISTORY:%03d\n' "$n"; done;;
          bytes)
            stty raw -echo
            printf '\r\nBINARY_READY\r\n'
            dd bs=1 count=9 2>/dev/null | od -An -tx1 | tr -s ' '
            stty -raw -echo
            ;;
          keys)
            stty raw -echo
            printf '\r\nKEYS_READY\r\n'
            dd bs=1 count=4 2>/dev/null | od -An -tx1 | tr -s ' '
            stty -raw -echo
            ;;
          paste)
            stty raw -echo
            printf '\033[?2004h\r\nPASTE_READY\r\n'
            dd bs=1 count=18 2>/dev/null | od -An -tx1 | tr -s ' '
            printf '\033[?2004l\r\nPASTE_DONE\r\n'
            stty -raw -echo
            ;;
          *) printf '\r\nINPUT:%s\n' "$action";;
        esac
      done
      """#
  }
}
