import Foundation
import Testing

@testable import supacode

/// Every pane resolves its session independently, but panes in one project all
/// enumerate the same transcript directory. That walk grows with the number of
/// files on disk rather than the number of panes, so the resolver shares one
/// walk across panes for a short window instead of repeating it per pane.
///
/// Reuse is asserted through observable behavior: a file created after a walk
/// is invisible while that walk is still being replayed, and visible once it
/// has expired.
struct AgentSessionRootScanCacheTests {
  private struct Layout {
    let home: URL
    /// The directory the Claude profile enumerates for `projectDirectory`.
    let root: URL
  }

  private func makeLayout() throws -> Layout {
    let home = FileManager.default.temporaryDirectory
      .appending(path: "prowl-root-scan-\(UUID().uuidString)", directoryHint: .isDirectory)
    // The profile only accepts UUID-named .jsonl files beneath /.claude/projects/.
    let root = home.appending(path: ".claude/projects/-tmp-project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return Layout(home: home, root: root)
  }

  @discardableResult
  private func writeTranscript(in root: URL, id: UUID = UUID()) throws -> URL {
    let url = root.appending(path: "\(id.uuidString.lowercased()).jsonl")
    try #"{"type":"user","message":{"content":"hello"}}"#.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func scan(
    _ resolver: AgentSessionResolver,
    root: URL,
    startedAt: Date,
    now: Date
  ) async -> [AgentSessionCandidate]? {
    await resolver.scanCandidates(
      in: [root],
      profile: AgentSessionProfile.profile(for: .claude),
      processStartedAt: startedAt,
      now: now
    )
  }

  @Test func aWalkIsReplayedForPanesArrivingWithinTheWindow() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.home) }
    try writeTranscript(in: layout.root)
    let resolver = AgentSessionResolver(fileManager: .default, homeDirectory: layout.home)
    let started = Date(timeIntervalSince1970: 1_000)
    let now = Date()

    let first = await scan(resolver, root: layout.root, startedAt: started, now: now)
    #expect(first?.count == 1)

    // A second transcript lands, as a newly started agent would produce.
    try writeTranscript(in: layout.root)
    let replayed = await scan(resolver, root: layout.root, startedAt: started, now: now.addingTimeInterval(0.5))
    #expect(replayed?.count == 1, "The shared walk is replayed, so the new file is not yet visible")
  }

  @Test func anExpiredWalkPicksUpNewTranscripts() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.home) }
    try writeTranscript(in: layout.root)
    let resolver = AgentSessionResolver(fileManager: .default, homeDirectory: layout.home)
    let started = Date(timeIntervalSince1970: 1_000)
    let now = Date()

    _ = await scan(resolver, root: layout.root, startedAt: started, now: now)
    try writeTranscript(in: layout.root)

    // Past the window the directory is walked again, so a session that started
    // moments ago still becomes resolvable.
    let refreshed = await scan(resolver, root: layout.root, startedAt: started, now: now.addingTimeInterval(5))
    #expect(refreshed?.count == 2)
  }

  @Test func aWalkExpiresBeforeSoleCandidateConfirmationRetries() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.home) }
    try writeTranscript(in: layout.root)
    let resolver = AgentSessionResolver(fileManager: .default, homeDirectory: layout.home)
    let started = Date(timeIntervalSince1970: 1_000)
    let now = Date()

    _ = await scan(resolver, root: layout.root, startedAt: started, now: now)
    try writeTranscript(in: layout.root)

    // A medium-confidence sole candidate is confirmed on the next fresh resolver pass, whose
    // narrow retry interval is one second. Replaying an older walk at that point could confirm
    // the first transcript after the new agent's own transcript has already appeared.
    let confirmationPass = await scan(
      resolver,
      root: layout.root,
      startedAt: started,
      now: now.addingTimeInterval(1.01)
    )
    #expect(confirmationPass?.count == 2)
  }

  @Test func callersWithDifferentThresholdsShareOneWalk() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.home) }
    try writeTranscript(in: layout.root)
    let resolver = AgentSessionResolver(fileManager: .default, homeDirectory: layout.home)
    let now = Date()

    // The cached walk is stored unfiltered, so panes whose processes started at
    // very different times reuse it and each apply their own threshold.
    let old = await scan(resolver, root: layout.root, startedAt: Date(timeIntervalSince1970: 1_000), now: now)
    let future = await scan(resolver, root: layout.root, startedAt: now.addingTimeInterval(3_600), now: now)

    #expect(old?.count == 1, "A process older than the transcript sees it")
    #expect(future?.isEmpty == true, "A process started after the transcript does not")
  }

  @Test func separateRootsAreCachedIndependently() async throws {
    let layout = try makeLayout()
    defer { try? FileManager.default.removeItem(at: layout.home) }
    let other = layout.home.appending(path: ".claude/projects/-tmp-other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try writeTranscript(in: layout.root)
    try writeTranscript(in: other)
    try writeTranscript(in: other)
    let resolver = AgentSessionResolver(fileManager: .default, homeDirectory: layout.home)
    let started = Date(timeIntervalSince1970: 1_000)
    let now = Date()

    let first = await scan(resolver, root: layout.root, startedAt: started, now: now)
    let second = await scan(resolver, root: other, startedAt: started, now: now)

    #expect(first?.count == 1)
    #expect(second?.count == 2, "One root's cached walk must not answer for another")
  }
}
