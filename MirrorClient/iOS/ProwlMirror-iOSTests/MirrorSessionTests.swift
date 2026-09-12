import Foundation
import Testing

@testable import ProwlMirror_iOS

@MainActor
struct MirrorSessionTests {
  @Test func selectingAFreePaneDoesNotTakeOverANewerOwner() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    session.connect()
    transport.onMessage?(.panes(.init(panes: [pane], capabilities: ["text-v1"], hostRunID: UUID())))
    session.select(pane)
    #expect(transport.sent.last?.intent == .ifFree)
    transport.onMessage?(.failure(.init(error: "PANE_BUSY", subscriptionID: nil)))
    #expect(session.status == .takenOver)
    session.retry(takeover: true)
    transport.onMessage?(.panes(.init(panes: [pane], capabilities: ["text-v1"], hostRunID: UUID())))
    #expect(transport.sent.last?.intent == .takeover)
  }

  @Test func selectingABusyPaneUsesTheDisplayedTakeOverAction() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: true)
    session.connect()
    transport.onMessage?(.panes(.init(panes: [pane], capabilities: ["text-v1"], hostRunID: UUID())))
    session.select(pane)
    #expect(transport.sent.last?.intent == .takeover)
  }

  @Test func retryAfterEnrollmentUsesCredentialBeforeRuntimeReady() {
    let initial = MirrorSavedConnection(address: "127.0.0.1", port: 7880, pairingKey: "ABCD-2345")
    let enrolled = MirrorSavedConnection(
      address: initial.address, port: initial.port, pairingKey: "",
      credential: .init(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 7, count: 32)))
    let first = FakeTransport()
    first.reportsReady = false
    let second = FakeTransport()
    var configurations: [MirrorSavedConnection] = []
    let session = MirrorSession(configuration: initial) { configuration in
      configurations.append(configuration)
      return configurations.count == 1 ? first : second
    }
    session.connect()
    first.onEnrolled?(enrolled)
    #expect(first.sent.isEmpty)
    #expect(session.status == .connecting)
    first.onClose?("Runtime connection failed")
    session.retry()
    #expect(configurations == [initial, enrolled])
    #expect(session.configuration == enrolled)
    let stale = first.onEnrolled
    session.disconnect()
    stale?(initial)
    #expect(session.configuration == enrolled)
  }

  @Test func historyPagesStayFrozenAndDoNotReplaceLiveOutput() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    session.connect()
    transport.onMessage?(
      .panes(.init(panes: [pane], capabilities: ["text-v1", "history"], hostRunID: UUID())))
    session.select(pane)
    let lease = UUID()
    transport.onMessage?(
      .subscribed(.init(paneID: pane.id, subscriptionID: lease, hostRunID: UUID())))
    transport.onMessage?(
      .textFrame(.init(sequence: 1, text: "live", subscriptionID: lease)))
    session.loadHistory(refresh: true)
    let history = UUID()
    transport.onMessage?(
      .historyPage(
        .init(
          historyID: history, offset: 1, lines: ["last"], total: 2, subscriptionID: lease,
          capturedAt: 100, truncated: true)))
    session.loadHistory()
    #expect(transport.sent.last?.historyID == history)
    #expect(transport.sent.last?.offset == 1)
    transport.onMessage?(
      .historyPage(
        .init(
          historyID: history, offset: 0, lines: ["first"], total: 2, subscriptionID: lease,
          capturedAt: 100, truncated: true)))
    #expect(session.historyLines == ["first", "last"])
    #expect(session.historyTruncated)
    #expect(session.text == "live")
    transport.onMessage?(
      .textFrame(.init(sequence: 2, text: "new live", subscriptionID: lease)))
    #expect(session.historyLines == ["first", "last"])
    #expect(session.text == "new live")
    session.liveReadingOffset = 300
    session.historyReadingOffset = 200
    session.updateConnection(
      .init(
        address: "192.0.2.1", port: 7880,
        pairingKey: String(repeating: "a", count: 64)))
    #expect(session.historyLines.isEmpty)
    #expect(!session.showsHistory)
    #expect(session.liveReadingOffset == 0)
    #expect(session.historyReadingOffset == 0)
  }

  @Test func foregroundRefreshKeepsLeaseAndConnection() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    session.connect()
    transport.onMessage?(
      .panes(.init(panes: [pane], capabilities: ["text-v1", "refresh"], hostRunID: UUID())))
    session.select(pane)
    let lease = UUID()
    transport.onMessage?(
      .subscribed(.init(paneID: pane.id, subscriptionID: lease, hostRunID: UUID())))
    transport.onMessage?(
      .textFrame(.init(sequence: 1, text: "current", subscriptionID: lease)))
    session.foreground()
    #expect(transport.starts == 1)
    #expect(transport.sent.last?.kind == .refresh)
    #expect(transport.sent.last?.subscriptionID == lease)
    #expect(session.text == "current")
  }

  @Test func editingKeyUsesIfFreeAndSavesOnlyVerifiedNewConfiguration() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    var verified: MirrorSavedConnection?
    session.onVerifiedConnection = { verified = $0 }
    session.connect()
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    let listing: MirrorMessage = .panes(
      .init(panes: [pane], capabilities: ["text-v1"], hostRunID: UUID()))
    transport.onMessage?(listing)
    session.select(pane)
    session.draft = "keep this"
    let replacement = MirrorSavedConnection(
      address: "127.0.0.1", port: 7880,
      pairingKey: String(repeating: "b", count: 64))
    session.updateConnection(replacement)
    #expect(verified != replacement)
    transport.onMessage?(listing)
    #expect(verified == replacement)
    #expect(transport.sent.last?.intent == .ifFree)
    #expect(session.draft == "keep this")
  }

  @Test func retryIsIfFreeAndRepeatedClicksDoNotOpenMoreConnections() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    let listing: MirrorMessage = .panes(
      .init(panes: [pane], capabilities: ["text-v1"], hostRunID: UUID()))
    session.connect()
    transport.onMessage?(listing)
    session.select(pane)
    #expect(transport.sent.last?.intent == .ifFree)
    transport.onClose?("Network lost")
    session.retry()
    session.retry()
    #expect(transport.starts == 2)
    transport.onMessage?(listing)
    #expect(transport.sent.last?.intent == .ifFree)
    transport.onMessage?(.failure(.init(error: "PANE_BUSY", subscriptionID: nil)))
    session.foreground()
    #expect(transport.starts == 2)
    session.retry(takeover: true)
    transport.onMessage?(listing)
    #expect(transport.sent.last?.intent == .takeover)
    #expect(transport.starts == 3)
  }

  @Test func replacementsClearOldOutputAndAcknowledgeWithoutAView() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Fixture", directory: "/", busy: false)
    session.connect()
    transport.onMessage?(
      .panes(.init(panes: [pane], capabilities: ["text-v1"], hostRunID: UUID())))
    session.select(pane)
    let lease = UUID()
    transport.onMessage?(
      .subscribed(.init(paneID: pane.id, subscriptionID: lease, hostRunID: UUID())))
    session.draft = "未发送\n第二行"
    transport.onMessage?(
      .textFrame(.init(sequence: 1, text: "thinking", subscriptionID: lease)))
    transport.onMessage?(
      .textFrame(.init(sequence: 2, text: "", subscriptionID: lease)))
    #expect(session.text == "")
    #expect(session.draft == "未发送\n第二行")
    #expect(transport.sent.filter { $0.kind == .acknowledge }.count == 2)
    #expect(session.status == .live)
    transport.onMessage?(.ended(.init(reason: .takenOver)))
    session.foreground()
    #expect(session.status == .takenOver)
    #expect(transport.starts == 1)
  }

  @Test func cancelledAttemptCannotRestoreSubscription() {
    let transport = FakeTransport()
    let session = makeSession(transport)
    session.connect()
    let stale = transport.onMessage
    session.disconnect()
    stale?(.panes(.init(panes: [], capabilities: ["text-v1"], hostRunID: UUID())))
    #expect(session.status == .disconnected)
    session.foreground()
    #expect(transport.starts == 1)
  }

  private func makeSession(_ transport: FakeTransport) -> MirrorSession {
    MirrorSession(
      configuration: .init(
        address: "127.0.0.1", port: 7880, pairingKey: String(repeating: "a", count: 64)),
      makeTransport: { _ in transport })
  }

  private final class FakeTransport: MirrorTransport {
    var onEnrolled: ((MirrorSavedConnection) -> Void)?
    var onReady: (() -> Void)?
    var onMessage: ((MirrorMessage) -> Void)?
    var onClose: ((String?) -> Void)?
    var sent: [MirrorMessage] = []
    var starts = 0
    var reportsReady = true
    func start() {
      starts += 1
      if reportsReady { onReady?() }
    }
    func send(_ message: MirrorMessage, closeAfterSending: Bool) { sent.append(message) }
    func close(_ reason: String?) { onClose?(reason) }
  }
}
