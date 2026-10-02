import AppKit
import Clocks
import Foundation
import GhosttyKit
import Testing

@testable import supacode

@Suite(.serialized)
@MainActor
struct MirrorReplicaInputTests {
  @Test(.timeLimit(.minutes(2)), arguments: [false, true])
  func replayDoesNotForwardAutomaticTerminalReports(staticTitle: Bool) async throws {
    let runtime = GhosttyRuntime()
    let configFile = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".conf")
    defer { try? FileManager.default.removeItem(at: configFile) }
    func reloadTitle(_ title: String) throws {
      let config = try #require(ghostty_config_new())
      defer { ghostty_config_free(config) }
      try "title = \(title)\n".write(to: configFile, atomically: true, encoding: .utf8)
      ghostty_config_load_file(config, configFile.path)
      ghostty_config_finalize(config)
      ghostty_app_update_config(runtime.app, config)
    }
    if staticTitle { try reloadTitle("Fixed replica title") }
    let clock = TestClock()
    let replica = MirrorReplica(runtime: runtime, clock: clock)
    let lease = UUID()
    var input = Data()
    var acknowledged: UInt64 = 0
    replica.onMessage = { message in
      if case .input(let payload) = message { input.append(payload.bytes) }
      if case .acknowledge(let payload) = message { acknowledged = payload.sequence }
    }
    defer { replica.stop() }
    try replica.start()
    try await wait { replica.view != nil }
    let view = try #require(replica.view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    for sequence in 1...3 {
      if staticTitle, sequence == 2 { try reloadTitle("Reloaded fixed title") }
      replica.display(
        .frame(
          .init(
            frame: .init(
              columns: 80, rows: 24,
              bytes: Data("\u{1b}[?1004h\u{1b}[?2031h\u{1b}[?2048h\u{1b}[?2004hSCREEN \(sequence)".utf8)),
            sequence: UInt64(sequence), subscriptionID: lease)))
      try await wait { acknowledged == UInt64(sequence) }
    }
    // Reports are generated asynchronously after the helper writes and ACKs a frame.
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
    try await wait { ContinuousClock.now >= deadline }
    #expect(input.isEmpty, "Frame replay generated Host input: \(Array(input))")

    view.insertText("用户输入", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await wait {
      (String(data: input, encoding: .utf8) ?? "").contains("\u{1b}[200~用户输入\u{1b}[201~")
    }
    #expect(view.bridge.state.pwd?.contains("prowl-replica-") != true)
    #expect(view.bridge.state.title?.contains("prowl-replica-") != true)

    // A lost parser callback must report failure rather than hold Host's frame gate forever.
    var failure: String?
    replica.onFailure = { failure = $0 }
    view.bridge.consumeWorkingDirectory = { _ in true }
    replica.display(
      .frame(.init(frame: .init(columns: 80, rows: 24, bytes: Data("LAST".utf8)), sequence: 4, subscriptionID: lease)))
    await clock.advance(by: .seconds(30))
    #expect(failure?.contains("timed out") == true)
    #expect(acknowledged == 3)
  }

  private func wait(until condition: @MainActor () -> Bool) async throws {
    let (ticks, continuation) = AsyncStream<Void>.makeStream()
    let timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in continuation.yield(()) }
    defer {
      timer.invalidate()
      continuation.finish()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    for await _ in ticks {
      if condition() { return }
      if ContinuousClock.now >= deadline { throw Timeout() }
    }
    throw Timeout()
  }

  private struct Timeout: Error {}
}
