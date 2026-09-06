import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct HandoffStoreTests {
  // MARK: - Helpers

  private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "handoff-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func runGit(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path(percentEncoded: false)] + arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "HandoffStoreTests.Git",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: String(data: errorOutput, encoding: .utf8) ?? "git failed"]
      )
    }
    return String(data: output, encoding: .utf8) ?? ""
  }

  private let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)

  private let validBriefing = """
    # Handoff

    ## Objective
    Ship it.

    ## Current State
    Green.

    ## Next Steps
    1. Review.
    """

  // MARK: - parseShortstat (pure)

  @Test func parseShortstatExtractsInsertionsAndDeletions() {
    let (insertions, deletions) = HandoffStore.parseShortstat(
      " 3 files changed, 120 insertions(+), 14 deletions(-)"
    )
    #expect(insertions == 120)
    #expect(deletions == 14)
  }

  @Test func parseShortstatHandlesInsertionsOnly() {
    let (insertions, deletions) = HandoffStore.parseShortstat(" 1 file changed, 5 insertions(+)")
    #expect(insertions == 5)
    #expect(deletions == 0)
  }

  @Test func parseShortstatHandlesEmpty() {
    let (insertions, deletions) = HandoffStore.parseShortstat("")
    #expect(insertions == 0)
    #expect(deletions == 0)
  }

  // MARK: - validatedBriefing (pure)

  @Test func validatedBriefingAcceptsPlainDocument() {
    #expect(HandoffStore.validatedBriefing(from: validBriefing) == validBriefing + "\n")
  }

  @Test func validatedBriefingUnwrapsCodeFenceAndDropsPreamble() {
    let reply = """
      Sure! Here's the updated handoff:

      ```markdown
      # Handoff

      ## Objective
      Ship it.

      ## Current State
      Green.

      ## Next Steps
      1. Review.
      ```
      """
    let artifact = HandoffStore.validatedBriefing(from: reply)
    #expect(artifact?.hasPrefix("# Handoff") == true)
    #expect(artifact?.contains("```") == false)
    #expect(artifact?.contains("Sure!") == false)
  }

  @Test func validatedBriefingDropsChatterAfterTheClosingFence() {
    let reply = """
      ```markdown
      # Handoff

      ## Objective
      Ship the HUD.

      ## Current State
      Done, pending review.

      ## Next Steps
      1. Address review feedback.
      ```

      Let me know if you need anything else!
      """
    let artifact = HandoffStore.validatedBriefing(from: reply)
    #expect(artifact?.hasSuffix("1. Address review feedback.\n") == true)
    #expect(artifact?.contains("Let me know") == false)
  }

  @Test func validatedBriefingKeepsEmbeddedCodeBlocksIntact() {
    // A fence-wrapped reply whose document embeds its own code block: the
    // embedded pair closes before the wrapper's closing fence, so the last
    // fence line is the correct cut point and the block survives.
    let reply = """
      ```markdown
      # Handoff

      ## Objective
      Ship the HUD.

      ## Current State
      Done.

      ## Next Steps
      1. Run:
      ```
      make test
      ```
      ```
      """
    let artifact = HandoffStore.validatedBriefing(from: reply)
    #expect(artifact?.contains("make test") == true)
  }

  @Test func validatedBriefingNeverCutsAtAFenceInsideAnUnwrappedDocument() {
    // No wrapper fence: an embedded code block's fence lines are body
    // content, never a truncation point.
    let reply = """
      # Handoff

      ## Objective
      Ship the HUD.

      ## Current State
      Done.

      ## Next Steps
      1. Run:
      ```
      make test
      ```
      2. Push the branch.
      """
    let artifact = HandoffStore.validatedBriefing(from: reply)
    #expect(artifact?.contains("make test") == true)
    #expect(artifact?.contains("2. Push the branch.") == true)
  }

  @Test func validatedBriefingRejectsUnusableText() {
    #expect(HandoffStore.validatedBriefing(from: "") == nil)
    #expect(HandoffStore.validatedBriefing(from: "I could not update the file.") == nil)
    // Missing required sections.
    #expect(HandoffStore.validatedBriefing(from: "# Handoff\n\n## Objective\nOnly this.") == nil)
  }

  // MARK: - writeBriefing / removeCurrentArtifact

  @Test func writeBriefingCreatesCurrentArtifact() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)

    try store.writeBriefing(validBriefing + "\n", archivingPrevious: true, now: fixedDate)

    let content = try String(contentsOf: store.currentURL, encoding: .utf8)
    #expect(content == validBriefing + "\n")
    // First-ever write: nothing to archive.
    let archived = try FileManager.default.contentsOfDirectory(
      at: store.archiveDirectory,
      includingPropertiesForKeys: nil
    )
    #expect(archived.isEmpty)
  }

  @Test func writeBriefingArchivesReplacedArtifact() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)
    let previous = "# Handoff\n\n## Objective\nEarlier notes worth keeping.\n"
    try FileManager.default.createDirectory(at: store.handoffDirectory, withIntermediateDirectories: true)
    try previous.write(to: store.currentURL, atomically: true, encoding: .utf8)

    try store.writeBriefing(validBriefing + "\n", archivingPrevious: true, now: fixedDate)

    let archived = try FileManager.default.contentsOfDirectory(
      at: store.archiveDirectory,
      includingPropertiesForKeys: nil
    )
    let backup = try #require(archived.first { $0.lastPathComponent.contains("-replaced-current") })
    #expect(archived.count == 1)
    #expect(try String(contentsOf: backup, encoding: .utf8) == previous)
    #expect(try String(contentsOf: store.currentURL, encoding: .utf8) == validBriefing + "\n")
  }

  @Test func writeBriefingWithoutArchivingLeavesArchiveAlone() throws {
    // The transition path archives the outgoing state as a combined snapshot
    // first, so its write must not add a second backup.
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)
    let previous = "# Handoff\n\n## Objective\nOutgoing round.\n"
    try FileManager.default.createDirectory(at: store.handoffDirectory, withIntermediateDirectories: true)
    try previous.write(to: store.currentURL, atomically: true, encoding: .utf8)

    try store.writeBriefing(validBriefing + "\n", archivingPrevious: false, now: fixedDate)

    let archived = try FileManager.default.contentsOfDirectory(
      at: store.archiveDirectory,
      includingPropertiesForKeys: nil
    )
    #expect(archived.isEmpty)
    #expect(try String(contentsOf: store.currentURL, encoding: .utf8) == validBriefing + "\n")
  }

  @Test func removeCurrentArtifactDeletesAndToleratesAbsence() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)

    // Absent: a no-op.
    try store.removeCurrentArtifact()

    try store.writeBriefing(validBriefing + "\n", archivingPrevious: false, now: fixedDate)
    #expect(store.hasCurrentArtifact)
    try store.removeCurrentArtifact()
    #expect(!store.hasCurrentArtifact)
  }

  // MARK: - layout

  @Test func layoutSelfIgnoresHandoffInGitRepository() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    _ = try runGit(["init", "--quiet"], in: root)
    let store = HandoffStore(rootURL: root)

    try store.ensureLayout()

    let ignore = try String(contentsOf: store.ignoreURL, encoding: .utf8)
    #expect(ignore == "*\n")
    #expect(try runGit(["status", "--porcelain"], in: root).isEmpty)
  }

  @Test func layoutNeverSeedsCurrentArtifact() throws {
    // current.md exists iff a validated briefing produced it — no template.
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)

    try store.ensureLayout()
    _ = try store.save(outgoingAgent: "codex", note: nil, now: fixedDate)

    #expect(!store.hasCurrentArtifact)
  }

  // MARK: - save (filesystem; non-git root)

  @Test func saveKeepsNonASCIIChangedFileNamesReadable() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    _ = try runGit(["init", "--quiet"], in: root)
    try "draft".write(to: root.appending(path: "交接记录.md"), atomically: true, encoding: .utf8)
    let store = HandoffStore(rootURL: root)

    let result = try store.save(outgoingAgent: "codex", note: nil, now: fixedDate)

    #expect(result.changedFiles.contains { $0.contains("交接记录.md") })
    let context = try String(contentsOf: store.contextURL, encoding: .utf8)
    #expect(context.contains("交接记录.md"))
  }

  @Test func saveWritesAppendixForNonGitRoot() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)

    let result = try store.save(outgoingAgent: "codex", note: "wip", now: fixedDate)

    let context = try String(contentsOf: store.contextURL, encoding: .utf8)
    #expect(context.contains("Outgoing agent (detected): codex"))
    #expect(context.contains("(not a git repo)"))
    #expect(result.outgoingAgent == "codex")
    // A non-git root contributes no git repos summary count.
    #expect(result.totalChangedFiles == 0)
  }

  @Test func saveRecordsBriefingOnLogLine() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)

    _ = try store.save(outgoingAgent: "codex", note: nil, briefing: .inline, now: fixedDate)

    let log = try String(contentsOf: store.logURL, encoding: .utf8)
    #expect(log.contains("briefing=inline"))
  }

  @Test func saveWritesSessionContextExcerpt() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)
    let sessionContext = HandoffStore.SessionContext(
      agent: "codex",
      sessionID: "codex-session",
      paneID: "pane-123",
      paneTitle: "codex",
      source: "terminal-scrollback",
      confidence: "fallback",
      transcriptPath: "/tmp/codex.jsonl",
      excerptText: "Implemented handoff session context.\nNext: run tests."
    )

    let result = try store.save(
      outgoingAgent: "codex",
      sessionContext: sessionContext,
      note: nil,
      now: fixedDate
    )

    let session = try #require(result.sessionContext)
    #expect(session.excerptPath?.hasPrefix("handoff/sessions/") == true)
    let excerptPath = try #require(session.excerptPath?.replacing("handoff/", with: ""))
    let excerptURL = store.handoffDirectory.appending(path: excerptPath)
    let excerpt = try String(contentsOf: excerptURL, encoding: .utf8)
    #expect(excerpt.contains("# Handoff Session Context"))
    #expect(excerpt.contains("Session ID: codex-session"))
    #expect(excerpt.contains("Native transcript: /tmp/codex.jsonl"))
    #expect(excerpt.contains("Implemented handoff session context."))

    let context = try String(contentsOf: store.contextURL, encoding: .utf8)
    #expect(context.contains("Session Context:"))
    #expect(context.contains("Session ID: codex-session"))
    #expect(context.contains(".prowl/handoff/sessions/"))
  }

  @Test func saveWritesUniqueSessionContextExcerptsForSameTimestamp() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)
    let sessionContext = HandoffStore.SessionContext(
      agent: "codex",
      paneID: "pane-123",
      paneTitle: "codex",
      source: "terminal-scrollback",
      confidence: "fallback",
      excerptText: "first excerpt"
    )

    let first = try store.save(
      outgoingAgent: "codex",
      sessionContext: sessionContext,
      note: nil,
      now: fixedDate
    )
    let second = try store.save(
      outgoingAgent: "codex",
      sessionContext: sessionContext,
      note: nil,
      now: fixedDate
    )

    let firstPath = try #require(first.sessionContext?.excerptPath)
    let secondPath = try #require(second.sessionContext?.excerptPath)
    #expect(firstPath != secondPath)
    #expect(secondPath.hasSuffix("-2.md"))

    let firstURL = store.handoffDirectory.appending(
      path: firstPath.replacingOccurrences(of: "handoff/", with: "")
    )
    let secondURL = store.handoffDirectory.appending(
      path: secondPath.replacingOccurrences(of: "handoff/", with: "")
    )
    #expect(FileManager.default.fileExists(atPath: firstURL.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: secondURL.path(percentEncoded: false)))
  }
  @Test func reserveFileURLIsExclusiveAcrossConcurrentCalls() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let directory = root.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let reserved = try await withThrowingTaskGroup(of: URL.self, returning: [URL].self) { group in
      for _ in 0..<40 {
        group.addTask {
          try HandoffStore.reserveFileURL(in: directory, stem: "same", fileExtension: "md")
        }
      }
      var urls: [URL] = []
      for try await url in group {
        urls.append(url)
      }
      return urls
    }

    #expect(Set(reserved).count == 40)
    #expect(reserved.allSatisfy { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
  }

  @Test func saveTwiceReplacesGeneratedContext() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)

    _ = try store.save(outgoingAgent: "codex", note: nil, now: fixedDate)
    _ = try store.save(outgoingAgent: "claude", note: nil, now: fixedDate)

    let content = try String(contentsOf: store.contextURL, encoding: .utf8)
    #expect(content.contains("Outgoing agent (detected): claude"))
    #expect(!content.contains("Outgoing agent (detected): codex"))
  }

  @Test func saveNeverTouchesCurrentArtifact() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)
    try store.writeBriefing(validBriefing + "\n", archivingPrevious: false, now: fixedDate)

    _ = try store.save(outgoingAgent: "claude", note: nil, now: fixedDate)

    let updated = try String(contentsOf: store.currentURL, encoding: .utf8)
    #expect(updated == validBriefing + "\n")
    let context = try String(contentsOf: store.contextURL, encoding: .utf8)
    #expect(context.contains("Outgoing agent (detected): claude"))
  }

  // MARK: - log + archive

  @Test func appendLogGrowsAndArchiveCopies() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)

    try store.writeBriefing(validBriefing + "\n", archivingPrevious: false, now: fixedDate)
    _ = try store.save(outgoingAgent: "codex", note: nil, now: fixedDate)
    try store.appendLog("codex → claude", now: fixedDate)

    let log = try String(contentsOf: store.logURL, encoding: .utf8)
    #expect(log.contains("codex → claude"))
    #expect(log.split(separator: "\n").filter { $0.hasPrefix("- ") }.count >= 2)

    let archivedRelative = try store.archiveCurrent(from: "codex", toAgent: "claude", now: fixedDate)
    #expect(archivedRelative != nil)
    #expect(archivedRelative?.hasPrefix("handoff/archive/") == true)
    #expect(archivedRelative?.contains("codex-to-claude") == true)
    let archiveURL = store.handoffDirectory.appending(
      path: try #require(archivedRelative).replacing("handoff/", with: "")
    )
    let archive = try String(contentsOf: archiveURL, encoding: .utf8)
    #expect(archive.contains("## Objective"))
    #expect(archive.contains("# Handoff Context (generated)"))
    // current.md remains until the transition decides its fate.
    #expect(store.hasCurrentArtifact)
  }

  @Test func archiveCurrentReturnsNilWithoutArtifact() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)

    _ = try store.save(outgoingAgent: "codex", note: nil, now: fixedDate)

    #expect(try store.archiveCurrent(from: "codex", toAgent: "claude", now: fixedDate) == nil)
  }

  @Test func appendLogPreservesConcurrentEntries() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)
    let date = fixedDate

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<40 {
        group.addTask {
          try store.appendLog("event=\(index)", now: date)
        }
      }
      try await group.waitForAll()
    }

    let log = try String(contentsOf: store.logURL, encoding: .utf8)
    let entries = log.split(separator: "\n").filter { $0.hasPrefix("- ") }
    #expect(entries.count == 40)
    for index in 0..<40 {
      #expect(entries.contains { $0.contains("event=\(index)") })
    }
  }

  @Test func archiveCurrentKeepsExistingSameTimestampArchives() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)

    try store.writeBriefing(validBriefing + "\n", archivingPrevious: false, now: fixedDate)
    _ = try store.save(outgoingAgent: "codex", note: nil, now: fixedDate)
    let first = try #require(try store.archiveCurrent(from: "codex", toAgent: "claude", now: fixedDate))
    let second = try #require(try store.archiveCurrent(from: "codex", toAgent: "claude", now: fixedDate))

    #expect(first != second)
    #expect(first.hasSuffix(".md"))
    #expect(second.hasSuffix("-2.md"))

    let firstURL = store.handoffDirectory.appending(
      path: first.replacingOccurrences(of: "handoff/", with: "")
    )
    let secondURL = store.handoffDirectory.appending(
      path: second.replacingOccurrences(of: "handoff/", with: "")
    )
    #expect(FileManager.default.fileExists(atPath: firstURL.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: secondURL.path(percentEncoded: false)))
  }
}
