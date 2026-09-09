import AppKit
import ComposableArchitecture
import Darwin
import GhosttyKit
import Observation
import Synchronization
import Testing

@testable import supacode

@Suite(.serialized)
@MainActor
struct MirrorTerminalIntegrationTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["PROWL_RUN_LIVE_CONTROL_CONSOLE"] == "1"),
    .timeLimit(.minutes(3)))
  func liveControlConsoleReadsItsBundledGuideAndCLI() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let executable = try #require(ProcessInfo.processInfo.environment["PROWL_MIRROR_CODEX_EXECUTABLE"])
    var environment = Fixture.liveAgentEnvironment
    environment["PATH"] =
      URL(fileURLWithPath: executable).deletingLastPathComponent().path
      + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
    let profile = AgentProfile(
      name: "Local console smoke", runtime: .codex,
      environmentOverrides: environment.keys.sorted().map {
        AgentProfileEnvironmentOverride(name: $0, value: environment[$0]!)
      })
    let console = HostControlConsole(manager: fixture.manager, profiles: [profile], defaults: fixture.defaults)
    console.enabled = true
    console.directory = try #require(ProcessInfo.processInfo.environment["PROWL_TEST_CONSOLE_DIRECTORY"])
    console.profile.executionMode = .unrestricted
    let store = Store(initialState: AppFeature.State()) { AppFeature() }
    let router = SupacodeApp.makeCLICommandRouter(appStore: store, terminalManager: fixture.manager)
    let acceptedConnections = Mutex(0)
    console.makeServer = {
      let server = CLISocketServer(
        router: router, socketPath: "/tmp/prowl-console-\(UUID()).sock",
        onClientAccepted: { acceptedConnections.withLock { $0 += 1 } })
      try server.start()
      return server
    }
    defer { console.stop() }
    fixture.host.start()
    try await fixture.wait("Host listener") { fixture.host.isRunning || fixture.host.error != nil }
    try #require(fixture.host.error == nil)
    console.start()
    try await fixture.wait("Control console launch", timeout: .seconds(30)) {
      !console.isStarting
    }
    try #require(console.error == nil)
    let launched = try #require(console.surface)
    let view = try #require(
      fixture.manager.stateIfExists(for: HostControlConsole.worktreeID)?.surfaces[launched.surfaceID])
    fixture.attach(view)
    let text = { view.readScreenContentsForCLI() ?? "" }
    try await fixture.wait("Control console startup", timeout: .seconds(45)) {
      text().contains("Hooks need review") || text().contains("ready") || text().contains("Ready")
    }
    if text().contains("Hooks need review") {
      try #require(ProcessInfo.processInfo.environment["PROWL_TEST_TRUST_CODEX_HOOKS"] == "1")
      try #require(view.sendCLIKeyToken("down"))
      try await fixture.wait("Trust hooks selected") { text().contains("› 2. Trust all and continue") }
      try #require(view.sendCLIKeyToken("enter"))
    }
    try await fixture.wait("Control console initialization", timeout: .seconds(90)) {
      let screen = text()
      return screen.contains("prowl") && (screen.contains("ready") || screen.contains("Ready"))
        && acceptedConnections.withLock { $0 > 0 }
        && fixture.source.submissionState(view.id).canSubmit
    }
    #expect(console.isAlive)
    #expect(fixture.manager.controlConsoleSocketPath != nil)
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["PROWL_RUN_LIVE_MIRROR_CLAUDE"] == "1"),
    .timeLimit(.minutes(2)))
  func liveClaudeComposerCapture() async throws {
    let value = try #require(ProcessInfo.processInfo.environment["PROWL_MIRROR_CLAUDE_ARGV"])
    let arguments = try JSONDecoder().decode([String].self, from: Data(value.utf8))
    try #require(!arguments.isEmpty)
    let fixture = try Fixture(agentArguments: arguments)
    defer { fixture.close() }
    try await fixture.wait("Claude startup", timeout: .seconds(45)) {
      fixture.hostText.contains("Quick safety check:")
        || fixture.hostText.contains("bypass permissions on")
    }
    if fixture.hostText.contains("Quick safety check:") {
      // Only this fixture's newly created, empty directory may be trusted here.
      let unwrapped = fixture.hostText.filter { !$0.isWhitespace }
      try #require(unwrapped.contains(fixture.directory.lastPathComponent))
      #expect(fixture.hostView.sendCLIKeyToken("enter"))
    }
    try await fixture.wait("Claude composer", timeout: .seconds(30)) {
      fixture.hostText.contains("bypass permissions on")
    }
    let snapshot = try fixture.source.snapshot(fixture.hostView.id)
    let evidence = try #require(MirrorSnapshotEvidence.read(snapshot))
    if let output = ProcessInfo.processInfo.environment["PROWL_MIRROR_CAPTURE_FILE"] {
      try JSONEncoder().encode(snapshot).write(to: URL(fileURLWithPath: output))
    }
    #expect(evidence.lines.flatMap { $0.map(\.text) }.joined().contains("❯"))
    #expect(evidence.hasEmptyClaudeComposer)
    try await fixture.wait("Claude submission readiness", timeout: .seconds(30)) {
      fixture.source.submissionState(fixture.hostView.id).canSubmit
    }
    let ready = fixture.source.submissionState(fixture.hostView.id)
    fixture.hostView.insertText(
      "LOCAL_DRAFT", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!fixture.source.submissionState(fixture.hostView.id).canSubmit)
    #expect(
      fixture.source.submit("MUST_NOT_SEND", to: fixture.hostView.id, expected: ready).status
        == .rejected)
    try await fixture.wait("Claude local draft") { fixture.hostText.contains("LOCAL_DRAFT") }
    #expect(fixture.hostView.sendCLIKeyToken("ctrl-u"))
    try await fixture.wait("Claude empty composer restored") {
      fixture.source.submissionState(fixture.hostView.id).canSubmit
    }
    let current = fixture.source.submissionState(fixture.hostView.id)
    let outcome = fixture.source.submit(
      "Do not use tools or modify files.\nReply with exactly MIRROR_NATIVE_GLM_OK.",
      to: fixture.hostView.id, expected: current)
    try #require(outcome.status == .accepted)
    #expect(
      fixture.source.submit("MUST_NOT_DUPLICATE", to: fixture.hostView.id, expected: current).status
        == .rejected)
    try await fixture.wait("Claude reply to native submission", timeout: .seconds(45)) {
      fixture.hostText.split(separator: "\n").contains {
        $0.trimmingCharacters(in: .whitespaces) == "⏺ MIRROR_NATIVE_GLM_OK"
      }
    }
    #expect(!fixture.hostText.contains("MUST_NOT_SEND"))
    #expect(!fixture.hostText.contains("MUST_NOT_DUPLICATE"))
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["PROWL_RUN_LIVE_MIRROR_CODEX"] == "1"),
    .timeLimit(.minutes(2)))
  func liveCodexComposerRejectsHostDraft() async throws {
    let executable = try #require(
      ProcessInfo.processInfo.environment["PROWL_MIRROR_CODEX_EXECUTABLE"])
    let fixture = try Fixture(codexPath: executable)
    defer { fixture.close() }
    try await fixture.wait("Codex startup", timeout: .seconds(45)) {
      fixture.hostText.contains("Hooks need review")
        || fixture.source.submissionState(fixture.hostView.id).canSubmit
    }
    if fixture.hostText.contains("Hooks need review") {
      try #require(fixture.hostText.contains("3. Continue without trusting"))
      let trustHooks = ProcessInfo.processInfo.environment["PROWL_TEST_TRUST_CODEX_HOOKS"] == "1"
      // Trust requires an explicit local opt-in; ordinary test runs skip hooks.
      try #require(fixture.hostView.sendCLIKeyToken("down"))
      if !trustHooks { try #require(fixture.hostView.sendCLIKeyToken("down")) }
      try #require(fixture.hostView.sendCLIKeyToken("enter"))
    }
    do {
      try await fixture.wait("Codex submission readiness", timeout: .seconds(60)) {
        fixture.source.submissionState(fixture.hostView.id).canSubmit
      }
    } catch {
      throw Failure(
        reason: "\(error); \(fixture.source.submissionState(fixture.hostView.id).reason); "
          + String(reflecting: fixture.hostText.suffix(1200)))
    }
    let ready = fixture.source.submissionState(fixture.hostView.id)
    fixture.hostView.insertText(
      "LOCAL_DRAFT", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!fixture.source.submissionState(fixture.hostView.id).canSubmit)
    let rejected = fixture.source.submit("MUST_NOT_SEND", to: fixture.hostView.id, expected: ready)
    #expect(rejected.status == .rejected)
    try await fixture.wait("local draft visible") { fixture.hostText.contains("LOCAL_DRAFT") }
    #expect(!fixture.hostText.contains("MUST_NOT_SEND"))
    #expect(fixture.hostView.sendCLIKeyToken("ctrl-u"))
    try await fixture.wait("empty composer ready again") {
      fixture.source.submissionState(fixture.hostView.id).canSubmit
    }
    if ProcessInfo.processInfo.environment["PROWL_MIRROR_CODEX_SEND"] == "1" {
      let current = fixture.source.submissionState(fixture.hostView.id)
      let outcome = fixture.source.submit(
        "Do not use tools or modify files.\nReply with exactly MIRROR_NATIVE_SUBMIT_OK.",
        to: fixture.hostView.id, expected: current)
      try #require(outcome.status == .accepted)
      #expect(
        fixture.source.submit("MUST_NOT_DUPLICATE", to: fixture.hostView.id, expected: current)
          .status == .rejected)
      try await fixture.wait("Codex reply to native submission", timeout: .seconds(60)) {
        fixture.hostText.split(separator: "\n").contains {
          $0.trimmingCharacters(in: .whitespaces) == "• MIRROR_NATIVE_SUBMIT_OK"
        }
      }
      #expect(!fixture.hostText.contains("MUST_NOT_DUPLICATE"))
    }
  }

  @Test(.timeLimit(.minutes(2))) func boundedCaptureAndSnapshotEvidenceUseRealSurface() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    try fixture.send("history")
    try await fixture.wait("history output") { fixture.hostText.contains("HISTORY:450") }
    let before = try fixture.source.snapshot(fixture.hostView.id)
    let evidence = try #require(MirrorSnapshotEvidence.read(before))
    #expect(evidence.lines.flatMap { $0.map(\.text) }.joined().contains("HISTORY:450"))
    let surface = try #require(fixture.hostView.surface)
    var captured = ghostty_text_s()
    var truncated = false
    try #require(ghostty_surface_read_text_bounded(surface, false, 2, 4096, &captured, &truncated))
    defer { ghostty_surface_free_text(surface, &captured) }
    let bytes = try #require(captured.text)
    let text = try #require(
      String(
        bytes: UnsafeRawBufferPointer(start: bytes, count: Int(captured.text_len)), encoding: .utf8)
    )
    #expect(truncated)
    #expect(text.contains("HISTORY:450"))
    #expect(!text.contains("HISTORY:001"))
    #expect(try fixture.source.snapshot(fixture.hostView.id) == before)
    var untouched = ghostty_text_s()
    untouched.offset_start = 123
    untouched.text_len = 456
    var untouchedTruncated = true
    #expect(
      !ghostty_surface_read_text_bounded(surface, true, 1, 1, &untouched, &untouchedTruncated))
    #expect(untouched.offset_start == 123)
    #expect(untouched.text_len == 456)
    #expect(untouched.text == nil)
    #expect(untouchedTruncated)
    #expect(try fixture.source.snapshot(fixture.hostView.id) == before)
    #expect(try fixture.source.activeText(fixture.hostView.id).contains("HISTORY:450"))
  }

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
    try await verifyTakeover(fixture, first: client)

    client.close()
    try await fixture.wait("unsubscribe") { fixture.host.subscriberCount == 0 }
    try fixture.send("after-close")
    try await fixture.wait("Host survives mirror close") {
      fixture.hostText.contains("INPUT:after-close")
    }
    let reconnected = try await fixture.connect()
    try await fixture.waitForMirror(reconnected, containing: "INPUT:after-close")
    fixture.host.stop()
    try await fixture.wait("Client sees Host stop") { !reconnected.isConnected }
    #expect(reconnected.error != nil)
    #expect(reconnected.replica.view != nil)
    #expect(reconnected.endReason == .hostStopped)
    try fixture.send("after-stop")
    try await fixture.wait("Host survives server stop") {
      fixture.hostText.contains("INPUT:after-stop")
    }
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
    let viewport = MirrorTerminalScrollView(
      surface: replica, displaySize: client.replica.displaySize)
    window.contentView = viewport
    window.setContentSize(NSSize(width: 320, height: 240))
    viewport.layoutSubtreeIfNeeded()
    #expect(replica.frame.height > viewport.contentSize.height)
    #expect(viewport.contentView.bounds.minY == 0)
    let event = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 80, wheel2: 0, wheel3: 0
      ))
    replica.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    try await fixture.wait("mirror viewport scroll") { viewport.contentView.bounds.minY > 0 }
    #expect(try fixture.frame(replica) == original)
    #expect(try fixture.source.snapshot(fixture.hostView.id) == original)
    viewport.contentView.scroll(to: .zero)
    window.setContentSize(NSSize(width: 280, height: 200))
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

  private func verifyTakeover(_ fixture: Fixture, first: MirrorClient) async throws {
    let second = fixture.makeClient()
    second.connect()
    try await fixture.wait("second discovery") { !second.panes.isEmpty || second.error != nil }
    let pane = try #require(second.panes.first)
    #expect(pane.busy)
    second.subscribe(pane)
    try await fixture.wait("second replica") { second.replica.view != nil || second.error != nil }
    fixture.attach(try #require(second.replica.view))
    try await fixture.wait("first taken over") { first.endReason == .takenOver }
    let frozen = fixture.replicaText(first)
    let oldReplica = try #require(first.replica.view)
    oldReplica.insertText(
      "must-not-forward", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(oldReplica.sendCLIKeyToken("enter"))
    try fixture.send("after-takeover")
    try await fixture.waitForMirror(second, containing: "INPUT:after-takeover")
    #expect(!fixture.hostText.contains("must-not-forward"))
    #expect(fixture.replicaText(first) == frozen)
    #expect(try fixture.source.activeText(fixture.hostView.id).contains("INPUT:after-takeover"))
    first.retry()
    try await fixture.wait("retry refuses to steal") { first.endReason == .takenOver }
    #expect(second.isSubscribed)
    first.retry(takeover: true)
    try await fixture.waitForMirror(first, containing: "INPUT:after-takeover")
    try await fixture.wait("second taken over") { second.endReason == .takenOver }
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

    init(codexPath: String? = nil, agentArguments: [String]? = nil) throws {
      directory = FileManager.default.temporaryDirectory.appending(
        path: "mirror-terminal-\(UUID())"
      ).resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let script = directory.appending(path: "terminal.sh")
      let command: String
      if let agentArguments {
        command = agentArguments.map { "'" + $0.replacing("'", with: "'\\''") + "'" }.joined(
          separator: " ")
      } else if let codexPath {
        let trust = "projects={\(String(reflecting: directory.path))={trust_level=\"trusted\"}}"
        command = [
          codexPath, "--no-alt-screen", "--sandbox", "read-only", "--ask-for-approval", "never",
          "-C", directory.path, "-c", trust,
        ]
        .map { "'" + $0.replacing("'", with: "'\\''") + "'" }.joined(separator: " ")
      } else {
        try Self.program.write(to: script, atomically: true, encoding: .utf8)
        command = "/bin/bash '\(script.path.replacing("'", with: "'\\''"))'"
      }
      previousRuntime = GhosttyRuntime.shared
      runtime = GhosttyRuntime()
      manager = WorktreeTerminalManager(runtime: runtime)
      let state = manager.state(
        for: Worktree(
          id: directory.path, name: "Mirror integration", detail: "", workingDirectory: directory,
          repositoryRootURL: directory))
      hostView = GhosttySurfaceView(
        runtime: runtime, workingDirectory: directory, context: GHOSTTY_SURFACE_CONTEXT_WINDOW,
        environment: codexPath == nil ? [:] : Self.liveAgentEnvironment,
        command: command)
      state.surfaces[hostView.id] = hostView
      let tab = state.tabManager.createTab(title: "Mirror integration", icon: nil)
      state.trees[tab] = SplitTree<GhosttySurfaceView>(view: hostView)
      state.focusedSurfaceIdByTab[tab] = hostView.id
      source = GhosttyMirrorPaneSource(manager: manager)
      suite = "MirrorTerminalIntegration-\(UUID())"
      defaults = try #require(UserDefaults(suiteName: suite))
      host = MirrorHost(source: source, defaults: defaults)
      host.address = "127.0.0.1"
      host.port = String(try MirrorTestPort.unusedPort())
      attach(hostView)
      if codexPath != nil || agentArguments != nil {
        state.wakeAgentDetection(for: hostView, tabId: tab)
      }
    }

    var hostText: String { hostView.readScreenContentsForCLI() ?? "" }

    static var liveAgentEnvironment: [String: String] {
      let environment = ProcessInfo.processInfo.environment
      return ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"].reduce(into: [:]) {
        result, name in
        if let value = environment["PROWL_TEST_" + name] { result[name] = value }
      }
    }

    func replicaText(_ client: MirrorClient) -> String {
      client.replica.view?.readScreenContentsForCLI() ?? ""
    }

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

    func send(_ command: String) throws {
      try source.write(Data((command + "\n").utf8), to: hostView.id)
    }

    func frame(_ view: GhosttySurfaceView) throws -> MirrorFrame {
      let surface = try #require(view.surface)
      var text = ghostty_text_s()
      try #require(ghostty_surface_read_snapshot(surface, &text))
      defer { ghostty_surface_free_text(surface, &text) }
      let bytes = try #require(text.text)
      let size = ghostty_surface_size(surface)
      return MirrorFrame(
        columns: UInt32(size.columns), rows: UInt32(size.rows),
        bytes: Data(bytes: bytes, count: Int(text.text_len)))
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
          reason:
            "\(error); host=\(host.columns)x\(host.rows):\(String(reflecting: hostText.prefix(300))); "
            + "replica=\(String(describing: replica?.columns))x\(String(describing: replica?.rows)):"
            + "\(String(reflecting: replicaText(client).prefix(300))); "
            + "hostVT=\(hostTail); replicaVT=\(replicaTail)"
        )
      }
    }

    func wait(
      _ label: String, timeout: Duration = .seconds(15),
      until condition: @MainActor () throws -> Bool
    )
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
        if ContinuousClock.now >= deadline {
          throw Failure(reason: "Timed out: \(label); " + String(reflecting: hostText.suffix(1600)))
        }
      }
      throw CancellationError()
    }

    func close() {
      for client in clients { client.close() }
      host.stop()
      for state in manager.activeWorktreeStates { state.closeAllSurfaces() }
      for window in windows { window.close() }
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
      GhosttyRuntime.shared = previousRuntime
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
