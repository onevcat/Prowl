import AppKit
import ComposableArchitecture
import Darwin
import GhosttyKit
import Network
import Observation
import ProwlCLIShared
import SwiftUI
import Synchronization
import Testing

@testable import Prowl

@Suite(.serialized)
@MainActor
struct MirrorTerminalIntegrationTests {
  @Test(.timeLimit(.minutes(1))) func styledNativeScrollbackSurvivesWideRowsAndReflow() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host ready") { fixture.hostText.contains("READY") }
    try await fixture.startHost()
    let client = try await fixture.connect()
    try fixture.send("wrapped")
    try await fixture.wait("Wide output received") { fixture.replicaText(client).contains("W250") }
    let replica = try #require(client.replica.view)
    let originalFont = try #require(ghostty_surface_quicklook_font(try #require(replica.surface)))
    let font = Unmanaged<CTFont>.fromOpaque(originalFont).takeRetainedValue()
    let clipboard = NSPasteboard.general.changeCount
    for _ in 0..<3 {
      client.scroll(.upward)
      try await fixture.wait("Styled wrapped page") { !client.scrollState.isLoading }
      #expect(client.scrollState.error == nil)
      #expect(client.replica.usesStyledScrollback)
      #expect(client.replica.view === replica)
      let currentFont = try #require(ghostty_surface_quicklook_font(try #require(replica.surface)))
      let current = Unmanaged<CTFont>.fromOpaque(currentFont).takeRetainedValue()
      #expect(CTFontCopyPostScriptName(font) == CTFontCopyPostScriptName(current))
      #expect(CTFontGetSize(font) == CTFontGetSize(current))
    }
    #expect(NSPasteboard.general.changeCount == clipboard)
    fixture.hostView.setFrameSize(NSSize(width: 480, height: 420))
    fixture.hostView.updateSurfaceSize()
    try await fixture.wait("Styled resized page") {
      let terminal = try #require(fixture.hostView.surface)
      return client.replica.usesStyledScrollback
        && client.replica.view?.mirrorGrid?.columns
          == UInt32(ghostty_surface_size(terminal).columns)
    }
    client.scroll(.downward)
    try await fixture.wait("Styled downward page") { !client.scrollState.isLoading }
    #expect(client.replica.usesStyledScrollback)
  }

  @Test(.timeLimit(.minutes(1))) func remoteScrollMovesRealViewportAndPreservesFrozenHistory()
    async throws
  {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    let hostWindow = try #require(fixture.hostView.window)
    let wrapper = GhosttySurfaceScrollView(surfaceView: fixture.hostView, hostKind: .terminal)
    hostWindow.contentView = wrapper
    wrapper.layoutSubtreeIfNeeded()
    try await fixture.startHost()
    let client = try await fixture.connect()
    try fixture.send("focus-history")
    try await fixture.waitForMirror(client, containing: "HISTORY:450")
    try #require(client.supportsRemoteScroll)
    client.loadHistory(refresh: true)
    try await fixture.wait("Frozen history") { !client.isLoadingHistory }
    let history = client.historyLines
    let offset = client.historyOffset
    client.showsHistory = false
    let replica = try #require(client.replica.view)
    let window = try #require(replica.window)
    let store = RemoteMirrorStore(manager: fixture.manager, runtime: fixture.runtime)
    let hosting = NSHostingView(rootView: RemoteMirrorPaneView(client: client).environment(store))
    let container = NSView(frame: try #require(window.contentView).bounds)
    hosting.frame = container.bounds
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
    window.contentView = container
    func textView(_ view: NSView) -> NSTextView? {
      if let text = view as? NSTextView, text.accessibilityIdentifier() == "remote-mirror-viewport-text" { return text }
      return view.subviews.lazy.compactMap { textView($0) }.first
    }
    try await fixture.wait("Mounted viewport overlay") { textView(hosting) != nil }
    let overlay = try #require(textView(hosting))
    #expect(overlay.isHidden)
    hosting.layoutSubtreeIfNeeded()
    let viewportHeight = try #require(overlay.enclosingScrollView).frame.height
    fixture.manager.activeWorktreeStates.first { $0.surfaces[fixture.hostView.id] != nil }?
      .surfaceAgentStates[fixture.hostView.id] = PaneAgentState(detectedAgent: .codex)
    let initialText = try fixture.source.textSnapshot(fixture.hostView.id).text
    let pageRows = max(
      1, Int(ghostty_surface_size(try #require(fixture.hostView.surface)).rows) - 3)
    client.scroll(.upward)
    #expect(client.scrollState.isLoading)
    try await fixture.wait("Earlier remote viewport") {
      hosting.layoutSubtreeIfNeeded()
      #expect(overlay.enclosingScrollView?.frame.height == viewportHeight)
      return !client.scrollState.isLoading && client.viewportState.text != nil
    }
    #expect(client.scrollState.error == nil)
    let earlier = try #require(client.viewportState.text)
    #expect(try firstHistoryRow(initialText) - firstHistoryRow(earlier) == pageRows)
    #expect(!earlier.contains("HISTORY:450"))
    // The same Ghostty surface now displays native history, retaining its font and styles.
    #expect(client.replica.usesStyledScrollback)
    #expect(client.replica.view === replica)
    try verifyStyledReplica(replica, expected: earlier)
    #expect(earlier == (try fixture.sourceFrame()).viewportText)
    #expect(
      earlier.trimmingCharacters(in: .newlines)
        == (try fixture.source.textSnapshot(fixture.hostView.id)).text.trimmingCharacters(
          in: .newlines))
    try await fixture.wait("Observable pane retains the terminal renderer") { overlay.isHidden }
    var jumpedBack = false
    let stableUntil = ContinuousClock.now.advanced(by: .seconds(2))
    try await fixture.wait("Viewport stays scrolled across later polls") {
      if client.viewportState.text != earlier { jumpedBack = true }
      return ContinuousClock.now >= stableUntil
    }
    #expect(!jumpedBack)
    #expect(
      try fixture.source.snapshot(fixture.hostView.id).scrollBounds
        == .init(atTop: false, atBottom: false))
    do {
      let viewport = try #require(overlay.enclosingScrollView as? MirrorTerminalScrollView)
      viewport.updateViewportText(earlier)
      try verifyOverlayPreservesOtherInputFocus(overlay, container: container, window: window)
      viewport.updateViewportText(nil)
    }
    hosting.layoutSubtreeIfNeeded()
    #expect(client.historyLines == history)
    #expect(client.historyOffset == offset)
    client.scroll(.downward)
    try await fixture.wait("Latest remote viewport") {
      !client.scrollState.isLoading && client.viewportState.text == nil
    }
    try await fixture.wait("Observable pane restores styled active screen") { overlay.isHidden }
    #expect(!client.canScroll(.downward))
    #expect(client.canScroll(.upward))
    // A scrolled blank screen is still an overlay, not the nil clear signal.
    let viewport = try #require(overlay.enclosingScrollView as? MirrorTerminalScrollView)
    viewport.updateViewportText("")
    try await fixture.wait("Blank overlay remains visible") { !overlay.isHidden && overlay.string.isEmpty }
    client.scroll(.downward)
    try await fixture.wait("No-op boundary scroll completes") { !client.scrollState.isLoading }
    #expect(client.scrollState.error == nil)
    #expect(client.isSubscribed)
    #expect(client.historyLines == history)
  }

  private func verifyStyledReplica(_ replica: GhosttySurfaceView, expected: String) throws {
    let terminal = try #require(replica.surface)
    let size = ghostty_surface_size(terminal)
    let actual = try GhosttyMirrorPaneSource.viewportText(
      terminal, columns: UInt32(size.columns), rows: UInt32(size.rows), preserveRows: true)
    #expect(actual == expected)
    let archive = try #require(try GhosttyMirrorPaneSource.exportScrollback(replica))
    let styledText = try #require(String(data: archive, encoding: .utf8))
    #expect(styledText.contains("38;2;80;190;240"))
  }

  private func firstHistoryRow(_ text: String) throws -> Int {
    let row = try #require(text.split(separator: "\n").first { $0.hasPrefix("HISTORY:") })
    return try #require(Int(row.dropFirst("HISTORY:".count)))
  }

  private func verifyOverlayPreservesOtherInputFocus(
    _ overlay: NSTextView, container: NSView, window: NSWindow
  )
    throws
  {
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    container.addSubview(input)
    defer { input.removeFromSuperview() }
    try #require(window.makeFirstResponder(input))
    let responder = try #require(window.firstResponder)
    let shortcut = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f",
        isARepeat: false, keyCode: 3))
    _ = overlay.performKeyEquivalent(with: shortcut)
    #expect(window.firstResponder === responder)
  }

  @Test(.timeLimit(.minutes(1))) func remoteScrollReachesAlternateScreenApplication() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    try await fixture.startHost()
    let client = try await fixture.connect()
    try fixture.send("scroll-tui")
    try await fixture.waitForMirror(client, containing: "TUI-READY")
    #expect(try fixture.source.snapshot(fixture.hostView.id).scrollBounds == nil)
    client.scroll(.upward)
    try await fixture.waitForMirror(client, containing: "TUI-UP")
    try await fixture.wait("TUI up completed") { !client.scrollState.isLoading }
    #expect(client.scrollState.error == nil)
    #expect(try fixture.source.snapshot(fixture.hostView.id).scrollBounds == nil)
    client.scroll(.downward)
    try await fixture.waitForMirror(client, containing: "TUI-DOWN")
    try await fixture.wait("TUI down completed") { !client.scrollState.isLoading }
    #expect(client.scrollState.error == nil)
  }

  @Test(.timeLimit(.minutes(1))) func codexWheelProfileLimitsRealTUIEventCount() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host ready") { fixture.hostText.contains("READY") }
    try fixture.send("count-scroll")
    try await fixture.wait("Counter ready") { fixture.hostText.contains("COUNT:0") }
    fixture.manager.activeWorktreeStates.first { $0.surfaces[fixture.hostView.id] != nil }?
      .surfaceAgentStates[fixture.hostView.id] = PaneAgentState(detectedAgent: .codex)
    let rows = Int(ghostty_surface_size(try #require(fixture.hostView.surface)).rows)
    let events = GhosttyMirrorPaneSource.wheelEvents(paneRows: rows, agent: .codex)
    try fixture.source.scroll(.upward, to: fixture.hostView.id)
    try await fixture.wait("Converted TUI events consumed") { fixture.hostText.contains("COUNT:\(events)!") }
    try fixture.source.scroll(.downward, to: fixture.hostView.id)
    try await fixture.wait("Reverse TUI events consumed") { fixture.hostText.contains("COUNT:0!") }
  }

  @Test(.timeLimit(.minutes(1))) func textWireScrollsRealViewportAndKeepsHistorySnapshot() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    try fixture.send("history")
    try await fixture.wait("Host history ready") { fixture.hostText.contains("HISTORY:450") }
    try await fixture.startHost()
    let connection = MirrorRemoteConnection(
      configuration: .init(
        address: "127.0.0.1", port: UInt16(fixture.host.port)!, pairingKey: "", credential: fixture.credential),
      restore: { _ in nil }, persist: { _ in })
    defer { connection.close() }
    var messages: [MirrorMessage] = []
    connection.onReady = {
      connection.send(
        .subscribe(
          .init(
            paneID: fixture.hostView.id, representation: .text, intent: .ifFree, includeScrollState: true)))
    }
    connection.onMessage = { message in
      messages.append(message)
      if case .textFrame(let frame) = message {
        connection.send(.acknowledge(.init(sequence: frame.sequence, subscriptionID: frame.subscriptionID)))
      }
    }
    connection.start()
    try await fixture.wait("Mobile initial frame") { messages.last?.text?.contains("HISTORY:450") == true }
    let lease = try #require(messages.first?.subscriptionID)
    #expect(messages.last { $0.kind == .scrollState }?.scrollBounds == .init(atTop: false, atBottom: true))
    connection.send(.history(.init(historyID: nil, offset: nil, subscriptionID: lease)))
    try await fixture.wait("Mobile frozen history") { messages.last?.kind == .historyPage }
    let history = try #require(messages.last)
    let upward = UUID()
    connection.send(.scroll(.init(requestID: upward, direction: .upward, subscriptionID: lease)))
    try await fixture.wait("Mobile earlier viewport result") {
      messages.contains { $0.kind == .scrollResult && $0.scrollRequestID == upward }
    }
    let earlier = try #require(messages.last { $0.kind == .textFrame })
    #expect(earlier.text?.contains("HISTORY:450") == false)
    #expect(earlier.text == (try fixture.source.textSnapshot(fixture.hostView.id)).text)
    #expect(messages.last?.sequence == earlier.sequence)
    let earlierBounds = try #require(messages.last { $0.kind == .scrollState })
    #expect(earlierBounds.scrollBounds == .init(atTop: false, atBottom: false))
    #expect(earlierBounds.sequence == earlier.sequence)
    let downward = UUID()
    connection.send(.scroll(.init(requestID: downward, direction: .downward, subscriptionID: lease)))
    try await fixture.wait("Mobile latest viewport result") {
      messages.contains { $0.kind == .scrollResult && $0.scrollRequestID == downward }
    }
    #expect(messages.last { $0.kind == .textFrame }?.text?.contains("HISTORY:450") == true)
    #expect(messages.last { $0.kind == .scrollState }?.scrollBounds == .init(atTop: false, atBottom: true))
    connection.send(.history(.init(historyID: history.historyID, offset: nil, subscriptionID: lease)))
    try await fixture.wait("Mobile retained frozen history") { messages.last?.kind == .historyPage }
    #expect(messages.last?.lines == history.lines)
    #expect(messages.last?.historyID == history.historyID)
    #expect(!messages.contains { $0.kind == .viewport || $0.kind == .frame || $0.kind == .failure })
  }

  @Test(.timeLimit(.minutes(1))) func nativeBoundsUseGeometryAndStayUnknownForMouseApplications() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    #expect(try fixture.source.snapshot(fixture.hostView.id).scrollBounds == nil)
    try fixture.send("history")
    try await fixture.wait("Host history ready") { fixture.hostText.contains("HISTORY:450") }
    #expect(try fixture.source.snapshot(fixture.hostView.id).scrollBounds == .init(atTop: false, atBottom: true))
    fixture.hostView.performBindingAction("scroll_to_top")
    try await fixture.wait("Native scrollback top") {
      try fixture.source.snapshot(fixture.hostView.id).scrollBounds?.atTop == true
    }
    #expect(try fixture.source.textSnapshot(fixture.hostView.id).scrollBounds == .init(atTop: true, atBottom: false))
    try fixture.source.scroll(.downward, to: fixture.hostView.id)
    try await fixture.wait("Native scrollback middle") {
      try fixture.source.snapshot(fixture.hostView.id).scrollBounds == .init(atTop: false, atBottom: false)
    }
    fixture.hostView.performBindingAction("scroll_to_bottom")
    try await fixture.wait("Native bottom restored") {
      try fixture.source.snapshot(fixture.hostView.id).scrollBounds?.atBottom == true
    }
    try fixture.send("mouse-mode")
    try await fixture.wait("Application negotiated mouse reporting") { fixture.hostText.contains("MOUSE-READY") }
    // Even with retained native rows, a mouse-reporting application owns wheel
    // behavior, so native scrollbar positions cannot describe its boundaries.
    #expect(try fixture.source.snapshot(fixture.hostView.id).scrollBounds == nil)
    #expect(try fixture.source.textSnapshot(fixture.hostView.id).scrollBounds == nil)
  }

  @Test(.timeLimit(.minutes(1))) func viewportRowsPreserveWideCharacterWrapsAndResize() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    try fixture.send("wrapped")
    try await fixture.wait("Wrapped output ready") { fixture.hostText.contains("W250") }
    try fixture.source.scroll(.upward, to: fixture.hostView.id)
    var captured: MirrorFrame?
    try await fixture.wait("Wrapped viewport capture") {
      do {
        captured = try fixture.sourceFrame()
        return captured?.viewportText != nil
      } catch MirrorPaneSourceError.captureChanged { return false }
    }
    let first = try #require(captured)
    let text = try #require(first.viewportText)
    #expect(text.contains("界🙂X"))
    #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == Int(first.rows))
    fixture.hostView.setFrameSize(NSSize(width: 480, height: 420))
    fixture.hostView.updateSurfaceSize()
    try await fixture.wait("Reflow viewport capture") {
      do {
        captured = try fixture.sourceFrame()
        return captured?.columns != first.columns && captured?.viewportText != nil
      } catch MirrorPaneSourceError.captureChanged { return false }
    }
    let reflowed = try #require(captured)
    let reflowedText = try #require(reflowed.viewportText)
    #expect(reflowedText.split(separator: "\n", omittingEmptySubsequences: false).count == Int(reflowed.rows))
  }

  @Test(.timeLimit(.minutes(1))) func initialHostStartRecoversFromOccupiedPort() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let occupied = try NWListener(using: .tcp, on: .any)
    let ready = AsyncStream<Void>.makeStream()
    occupied.stateUpdateHandler = { state in
      if case .ready = state { ready.continuation.yield(()) }
    }
    occupied.newConnectionHandler = { $0.cancel() }
    occupied.start(queue: .main)
    defer {
      occupied.cancel()
      ready.continuation.finish()
    }
    var events = ready.stream.makeAsyncIterator()
    _ = await events.next()
    let port = try #require(occupied.port)
    fixture.host.port = String(port.rawValue)
    fixture.host.start()
    try await fixture.wait("Occupied Host port rejected") { fixture.host.error != nil }
    #expect(!fixture.host.isRunning)
    #expect(
      fixture.host.error
        == MirrorConnectionFailure.addressInUse.listenerMessage(address: fixture.host.address, port: fixture.host.port))
    try await fixture.startHost()
    #expect(fixture.host.isRunning)
    #expect(fixture.host.port != String(port.rawValue))
  }

  @Test(.timeLimit(.minutes(1))) func viewportRebindsWhenSelectedMirrorChanges() async throws {
    let first = try Fixture()
    defer { first.close() }
    let second = try Fixture()
    defer { second.close() }
    let hosting = NSHostingView(
      rootView: MirrorTerminalViewport(
        surface: first.hostView, displaySize: CGSize(width: 800, height: 600)))
    let window = try #require(first.windows.first)
    window.contentView = hosting
    func viewport(_ view: NSView) -> MirrorTerminalScrollView? {
      if let found = view as? MirrorTerminalScrollView { return found }
      return view.subviews.lazy.compactMap { viewport($0) }.first
    }
    try await first.wait("Initial represented terminal") {
      guard let scrollView = viewport(hosting) else { return false }
      return first.hostView.enclosingScrollView === scrollView
    }
    hosting.rootView = MirrorTerminalViewport(
      surface: second.hostView, displaySize: CGSize(width: 720, height: 480))
    try await first.wait("Selected represented terminal") {
      guard let scrollView = viewport(hosting) else { return false }
      return second.hostView.enclosingScrollView === scrollView
    }
    #expect(first.hostView.superview == nil)
  }

  @Test(.timeLimit(.minutes(1))) func retryReplacesFailedDisplayRelay() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    try await fixture.startHost()
    let client = try await fixture.connect()
    try await fixture.waitForMirror(client, containing: "READY")
    let oldView = try #require(client.replica.view)
    oldView.closeSurface()
    try await fixture.wait("Display failure disconnect") { !client.isConnected }
    client.retry()
    try await fixture.wait("Replacement display") {
      client.replica.view != nil && client.replica.view !== oldView
    }
    fixture.attach(try #require(client.replica.view))
    try fixture.send("relay-recovered")
    try await fixture.waitForMirror(client, containing: "INPUT:relay-recovered")
  }

  @Test(.timeLimit(.minutes(1)))
  func staleFreeSelectionDoesNotTakeOverAnotherMirror() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    try await fixture.startHost()
    let stale = fixture.makeClient()
    stale.connect()
    try await fixture.wait("Free discovery") { !stale.panes.isEmpty }
    let descriptor = try #require(stale.panes.first)
    #expect(!descriptor.busy)
    let owner = try await fixture.connect()
    try await fixture.waitForMirror(owner, containing: "READY")
    stale.subscribe(descriptor)
    try await fixture.wait("Stale selection outcome") {
      stale.endReason != nil || stale.isSubscribed
    }
    #expect(stale.endReason == .takenOver)
    #expect(!stale.isSubscribed)
    #expect(owner.isSubscribed)
  }

  @Test(.timeLimit(.minutes(1))) func retryUsesEnrollmentSavedBeforeAuthentication() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.startHost()
    fixture.host.addDevice()
    try await fixture.wait("Pairing listener") {
      fixture.host.isRunning && !fixture.host.isStarting
    }
    var interrupted = false
    var attempts: [MirrorSavedConnection] = []
    var connections: [MirrorRemoteConnection] = []
    let client = MirrorClient(
      configuration: .init(
        address: "127.0.0.1", port: UInt16(fixture.host.port)!,
        pairingKey: fixture.host.pairingKey), replica: MirrorReplica(runtime: fixture.runtime),
      makeConnection: { configuration in
        attempts.append(configuration)
        let connection = MirrorRemoteConnection(
          configuration: configuration, restore: { _ in nil },
          persist: { _ in
            if !interrupted {
              interrupted = true
              fixture.host.stop()
            }
          })
        connections.append(connection)
        return connection
      })
    fixture.clients.append(client)
    client.connect()
    try await fixture.wait("Enrollment persisted") { interrupted }
    connections.first?.close("Interrupted runtime authentication")
    #expect(!client.isConnecting)
    fixture.host.start()
    try await fixture.wait("Host restarted") { fixture.host.isRunning }
    client.connect()
    #expect(attempts.count == 2)
    #expect(attempts.last?.credential != nil)
    #expect(attempts.last?.pairingKey.isEmpty == true)
    guard attempts.last?.credential != nil else { return }
    try await fixture.wait("Retry discovery or failure") {
      !client.panes.isEmpty || !client.isConnecting
    }
    #expect(!client.panes.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func remoteInputWakesColdAgentDetection() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let id = fixture.hostView.id
    let state = try #require(fixture.manager.stateIfExists(for: fixture.directory.path))
    try await fixture.wait("Terminal surface") { fixture.hostView.surface != nil }
    #expect(state.agentDetectionTasks[id] == nil)
    try fixture.source.write(Data("\r".utf8), to: id)
    #expect(state.agentDetectionTasks[id] != nil)
    #expect(state.agentDetectionSchedules[id] != nil)
  }

  @Test(.timeLimit(.minutes(1))) func codexHintStylingSurvivesRealGhosttyCapture() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    try fixture.send("hint")
    try await fixture.wait("Dim hint rendered") {
      fixture.hostText.contains("Ask Codex to do anything")
    }
    let dim = try #require(fixture.hostView.readStyledSnapshotForCLI())
    #expect(CodexScreenProfile.composerHasNoDraft(styledSnapshot: dim))
    try fixture.send("draft")
    try await fixture.wait("Draft rendered") { fixture.hostText.contains("DRAFT") }
    let draft = try #require(fixture.hostView.readStyledSnapshotForCLI())
    #expect(!CodexScreenProfile.composerHasNoDraft(styledSnapshot: draft))
  }

  @Test(.timeLimit(.minutes(2))) func boundedCapturePreservesRealSurface() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    try fixture.send("history")
    try await fixture.wait("history output") { fixture.hostText.contains("HISTORY:450") }
    let before = try fixture.sourceFrame()
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
    #expect(try fixture.sourceFrame() == before)
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
    #expect(try fixture.sourceFrame() == before)
    #expect(try fixture.source.activeText(fixture.hostView.id).contains("HISTORY:450"))
  }

  @Test(.timeLimit(.minutes(1))) func paneLabelsDoNotChangeWhenAnotherTabOpens() throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let before = try #require(fixture.source.panes().first)
    let state = try #require(fixture.manager.activeWorktreeStates.first)
    _ = state.tabManager.createTab(title: "Another terminal", icon: nil)
    let after = try #require(fixture.source.panes().first)
    #expect(after.title == before.title)
    #expect(after.subtitle == before.subtitle)
    #expect(after.subtitle == "Mirror integration · Mirror integration")
  }

  @Test(.timeLimit(.minutes(2))) func realTerminalRoundTripAndLifecycle() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.wait("Host program ready") { fixture.hostText.contains("READY") }
    let descriptor = try #require(fixture.source.panes().first)
    #expect(descriptor.projectName == fixture.directory.lastPathComponent)
    #expect(descriptor.subtitle == "Mirror integration · Mirror integration")
    #expect(!descriptor.title.contains(fixture.hostView.id.uuidString.prefix(8)))
    try await fixture.startHost()
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
    let original = try fixture.sourceFrame()
    replica.setFrameSize(NSSize(width: 320, height: 240))
    replica.updateSurfaceSize()
    #expect(try fixture.sourceFrame() == original)
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
    #expect(viewport.magnification < 1)
    #expect(viewport.contentView.bounds.width >= client.replica.displaySize.width - 1)
    #expect(viewport.contentView.bounds.height >= client.replica.displaySize.height - 1)
    #expect(try fixture.frame(replica) == original)
    viewport.update(surface: replica, displaySize: client.replica.displaySize, fitsWindow: false)
    viewport.layoutSubtreeIfNeeded()
    #expect(viewport.magnification == 1)
    let initialTop: CGFloat = 0
    #expect(abs(viewport.contentView.bounds.minY - initialTop) < 1)
    // AppKit ignores synthetic wheel events for a hidden scroll view.
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    try await fixture.wait("Visible mirror viewport") { window.isVisible }
    try #require(replica.enclosingScrollView === viewport)
    try #require(replica.window === window)
    try #require(replica.mirrorGrid != nil)
    try #require(replica.frame.height > viewport.contentSize.height)
    let event = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -80, wheel2: 0, wheel3: 0
      ))
    replica.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    try await fixture.wait("mirror viewport scroll") { viewport.contentView.bounds.minY > initialTop + 1 }
    #expect(try fixture.frame(replica) == original)
    #expect(try fixture.sourceFrame() == original)
    let completion = UUID()
    viewport.updateScrollCompletion(completion)
    viewport.layoutSubtreeIfNeeded()
    #expect(viewport.contentView.bounds.minY == 0)
    replica.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    try await fixture.wait("Reading continues after completion") { viewport.contentView.bounds.minY > 1 }
    let manualOffset = viewport.contentView.bounds.origin
    viewport.updateScrollCompletion(completion)
    viewport.layoutSubtreeIfNeeded()
    #expect(viewport.contentView.bounds.origin == manualOffset)
    window.setContentSize(NSSize(width: 280, height: 200))
    viewport.layoutSubtreeIfNeeded()
    #expect(abs(viewport.contentView.bounds.minY - manualOffset.y) < 1)
    viewport.update(surface: replica, displaySize: client.replica.displaySize, fitsWindow: true)
    window.setContentSize(NSSize(width: 1600, height: 1200))
    viewport.layoutSubtreeIfNeeded()
    #expect(viewport.magnification == 1)
    #expect(viewport.contentView.bounds.minY == 0)
    #expect(viewport.documentView?.isFlipped == true)
    viewport.update(surface: replica, displaySize: client.replica.displaySize, fitsWindow: false)
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

  @Test(.timeLimit(.minutes(1))) func remoteShellCreationInDormantWorktreePreservesHostSelection()
    async throws
  {
    let fixture = try Fixture()
    defer { fixture.close() }
    let dormant = fixture.directory.appending(path: "dormant")
    try FileManager.default.createDirectory(at: dormant, withIntermediateDirectories: true)
    let dormantID = dormant.standardizedFileURL.path(percentEncoded: false)
    var initial = AppFeature.State()
    initial.repositories.repositories = IdentifiedArray(uniqueElements: [
      Repository(id: dormantID, rootURL: dormant, name: "Dormant", kind: .plain, worktrees: [])
    ])
    initial.repositories.repositoryRoots = [dormant]
    #expect(
      ListRuntimeSnapshotBuilder.orderedWorktreeContexts(from: initial.repositories).map(\.id) == [
        dormantID
      ])
    let store = Store(initialState: initial) { AppFeature() }
    fixture.manager.selectedWorktreeID = fixture.directory.path
    let hostState = try #require(fixture.manager.stateIfExists(for: fixture.directory.path))
    let selectedTab = hostState.tabManager.selectedTabId
    fixture.host.commandService = MirrorCommandService(
      router: ProwlApp.makeCLICommandRouter(appStore: store, terminalManager: fixture.manager),
      worktrees: {
        [
          ListCommandWorktree(
            id: dormantID, name: "Dormant", path: dormantID, rootPath: dormantID,
            kind: .plain)
        ]
      })
    try await fixture.startHost()
    let client = fixture.makeClient()
    client.connect()
    try await fixture.wait("command discovery") { client.isConnected && !client.isConnecting }
    #expect(client.supportsShellLaunch)
    let model = MirrorLaunchModel(
      supportsShell: true, supportsProfiles: false, execute: client.command)
    await model.load()
    #expect(model.worktrees.map(\.id) == [dormantID])
    let createdPane = await model.create()
    let pane = try #require(createdPane, "\(model.error ?? "Missing pane")")
    #expect(fixture.manager.selectedWorktreeID == fixture.directory.path)
    #expect(hostState.tabManager.selectedTabId == selectedTab)
    let createdState = try #require(fixture.manager.stateIfExists(for: dormantID))
    #expect(createdState.tabManager.tabs.count == 1)
    #expect(createdState.surfaces[pane.id] != nil)
    #expect(fixture.source.panes().contains { $0.id == pane.id })
    client.subscribe(pane)
    try await fixture.wait("created Shell subscription") {
      client.isSubscribed || client.error != nil
    }
    #expect(client.isSubscribed)
    #expect(client.error == nil)
  }

  private struct Failure: Error { let reason: String }

  @MainActor
  private final class Fixture {
    // Match the app lifetime: queued Ghostty wakeups carry unretained runtime pointers.
    // Surfaces and connections remain scoped to each fixture.
    private static let testRuntime = GhosttyRuntime()

    let directory: URL
    let runtime: GhosttyRuntime
    let manager: WorktreeTerminalManager
    let hostView: GhosttySurfaceView
    let source: GhosttyMirrorPaneSource
    let host: MirrorHost
    let credential: MirrorDeviceCredential
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
      runtime = Self.testRuntime
      GhosttyRuntime.shared = runtime
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
      let device = MirrorPairedDevice(
        id: UUID(), name: "Terminal test", key: try MirrorAuthentication.randomKey(),
        pairedAt: Date())
      var identity = MirrorHostIdentity(id: UUID(), devices: [device])
      credential = .init(hostID: identity.id, deviceID: device.id, key: device.key)
      host = MirrorHost(
        source: source, defaults: defaults, enabled: true,
        loadIdentity: { identity }, saveIdentity: { identity = $0 })
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

    func startHost() async throws {
      try await MirrorTestPort.startHost(host)
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
        configuration: .init(
          address: "127.0.0.1", port: UInt16(host.port)!, pairingKey: "", credential: credential),
        replica: MirrorReplica(runtime: runtime),
        makeConnection: {
          MirrorRemoteConnection(configuration: $0, restore: { _ in nil }, persist: { _ in })
        })
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

    func sourceFrame() throws -> MirrorFrame {
      let frame = try source.snapshot(hostView.id)
      // Display replicas omit Host-only report modes and separately delivered metadata.
      return .init(
        columns: frame.columns, rows: frame.rows,
        bytes: MirrorDisplayFrame.passiveSnapshot(frame.bytes), viewportText: frame.viewportText)
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
          return try self.sourceFrame() == self.frame(replica)
        }
      } catch {
        let host = try sourceFrame()
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
          throw Failure(
            reason: "Timed out: \(label); Host=\(host.address):\(host.port), "
              + "running=\(host.isRunning), starting=\(host.isStarting), error=\(host.error ?? "none"); "
              + String(reflecting: hostText.suffix(1600)))
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
          hint) printf '\033[2J\033[HHINT\r\n› \033[2mAsk Codex to do anything\033[0m\r\n  gpt-5.6 · ~/work';;
          draft) printf '\033[2J\033[HDRAFT\r\n› Ask Codex to do anything\r\n  gpt-5.6 · ~/work';;
          think) printf '\033[2J\033[H\033[31mTHINKING:思考中\033[0m\033[4;7H';;
          finish) printf '\033[2J\033[H\033[32mFINAL:结论\033[0m\033[2;3H';;
          history|focus-history)
            if [ "$action" = focus-history ]; then printf '\033[?1004h'; fi
            for ((n=1; n<=450; n++)); do printf '\033[38;2;80;190;240mHISTORY:%03d\033[0m\n' "$n"; done;;
          mouse-mode) printf '\033[?1000h\033[?1006hMOUSE-READY';;
          wrapped)
            columns=$(stty size); columns=${columns##* }
            for ((n=1; n<=250; n++)); do
              printf 'W%03d' "$n"
              printf '%*s' "$((columns-5))" ''
              printf '界🙂X\n'
            done
            ;;
          count-scroll)
            stty raw -echo
            printf '\033[?1049h\033[?1007h\033[2J\033[HCOUNT:0!'
            count=0
            while IFS= read -r -n 3 key; do
              case "$key" in
                $'\033[A') count=$((count+1));;
                $'\033[B') count=$((count-1));;
              esac
              printf '\033[2J\033[HCOUNT:%s!' "$count"
            done
            ;;
          scroll-tui)
            stty raw -echo
            printf '\033[?1049h\033[?1007h\033[2J\033[HTUI-READY'
            while IFS= read -r -n 3 key; do
              case "$key" in
                $'\033[A') printf '\033[2J\033[HTUI-UP';;
                $'\033[B') printf '\033[2J\033[HTUI-DOWN';;
              esac
            done
            ;;
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
