import Foundation
import Testing
@testable import ProwlCLIShared

struct WorkflowHistoryRetentionTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func expiryBudgetAndProtectionUseFinishTime() {
    let old = entry(days: 31)
    let eligible = entry(days: 2)
    let recent = entry(days: 0.5)
    let pinned = entry(days: 40, protection: "Keep Run")
    let active = entry(days: 50, protection: "Active")
    let corrupt = entry(days: 60, protection: "Unreadable")
    let entries = [recent, pinned, eligible, active, corrupt, old]
    let expiry = WorkflowHistoryPreview(entries: entries, now: now, budget: 1000)
    #expect(expiry.candidates.map(\.id) == [old.id])
    let budget = WorkflowHistoryPreview(entries: entries, now: now, budget: 1)
    #expect(budget.candidates.map(\.id) == [old.id, eligible.id])
    #expect(budget.remainingBytes == 40)
    #expect(budget.overBudget)
    #expect(budget.protectedEntries.count == 4)
  }

  @Test func cleanupRechecksPinAndOccupancyAndKeepsWholeRun() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let history = WorkflowHistory(storage: .init(baseURL: base))
    let a = try write(history, days: 31)
    let b = try write(history, days: 40)
    let preview = try history.preview(now: now)
    #expect(preview.candidates.count == 2)
    try history.keep(a, pinned: true)
    let occupied = try history.storage.occupy(b)
    let result = try history.cleanup(candidates: preview.candidates.map(\.id), now: now)
    #expect(result.removed.isEmpty)
    #expect(FileManager.default.fileExists(atPath: a.path))
    #expect(FileManager.default.fileExists(atPath: b.path))
    occupied.close()
    let second = try history.cleanup(candidates: preview.candidates.map(\.id), now: now)
    #expect(second.removed == [UUID(uuidString: b.lastPathComponent)!])
    #expect(!FileManager.default.fileExists(atPath: b.path))
  }

  @Test func corruptAndUnknownStatesAreProtected() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let history = WorkflowHistory(storage: .init(baseURL: base))
    let unknown = try write(history, days: 40, state: "future_state")
    let corrupt = try write(history, days: 40)
    try Data("broken".utf8).write(to: corrupt.appending(path: "run.json"))
    let preview = try history.preview(now: now)
    #expect(preview.candidates.isEmpty)
    #expect(preview.protectedEntries.count == 2)
    #expect(try history.storage.find(UUID(uuidString: unknown.lastPathComponent)!)?.path == unknown.path)
    #expect(throws: (any Error).self) { try history.export(unknown, to: base.appending(path: "bad.zip")) }
  }

  @Test func exportIsIndependentAndRejectsArtifactLinks() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let history = WorkflowHistory(storage: .init(baseURL: base.appending(path: "history")))
    let directory = try write(history, days: 31)
    let zip = base.appending(path: "run.zip")
    try history.export(directory, to: zip)
    #expect(FileManager.default.fileExists(atPath: zip.path))
    let outside = base.appending(path: "outside")
    try Data("keep".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: directory.appending(path: "artifact"), withDestinationURL: outside)
    #expect(throws: (any Error).self) { try history.export(directory, to: base.appending(path: "unsafe.zip")) }
    #expect(try history.preview(now: now).candidates.isEmpty)
    #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
  }

  @Test func maintenanceUsesInjectedTimeAndPreservesFailedUnits() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let history = WorkflowHistory(storage: .init(baseURL: base.appending(path: "history")))
    let old = try write(history, days: 40)
    #expect(try history.maintenance(now: now)?.removed == [UUID(uuidString: old.lastPathComponent)!])
    let failed = try write(history, days: 40)
    try Data().write(to: failed.appending(path: ".cleanup-failed"))
    #expect(try history.maintenance(now: now.addingTimeInterval(299)) == nil)
    #expect(try history.maintenance(now: now.addingTimeInterval(300))?.removed.isEmpty == true)
    #expect(throws: (any Error).self) { try history.export(failed, to: base.appending(path: "failed.zip")) }
    #expect(!FileManager.default.fileExists(atPath: base.appending(path: "failed.zip").path))
  }

  @Test func exportedArtifactsSurviveSourceCleanup() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let history = WorkflowHistory(storage: .init(baseURL: base.appending(path: "history")))
    let directory = try write(history, days: 40)
    let zip = base.appending(path: "run.zip")
    try history.export(directory, to: zip)
    _ = try history.cleanup(candidates: [UUID(uuidString: directory.lastPathComponent)!], now: now)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: "/usr/bin/unzip")
    process.arguments = ["-p", zip.path, "\(directory.lastPathComponent)/output.md"]
    process.standardOutput = output
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(String(data: bytes, encoding: .utf8) == "artifact")
  }

  @Test func duplicateUUIDsAreProtectedBeforeCleanupIsOffered() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let history = WorkflowHistory(storage: .init(baseURL: base))
    let source = try write(history, days: 40)
    let copy = history.storage.directory(
      root: URL(filePath: "/another-project"), createdAt: now, runID: UUID(uuidString: source.lastPathComponent)!)
    try history.storage.prepare(copy.deletingLastPathComponent())
    try FileManager.default.copyItem(at: source, to: copy)
    let preview = try history.preview(now: now)
    #expect(preview.candidates.isEmpty)
    #expect(preview.protectedEntries.count == 2)
  }

  private func entry(days: Double, protection: String? = nil) -> WorkflowHistoryEntry {
    WorkflowHistoryEntry(
      id: UUID(), directory: URL(filePath: "/test"), name: "Run", root: "/project", state: "completed",
      finishedAt: now.addingTimeInterval(-days * 86400), bytes: 10, pinned: false, protection: protection)
  }

  private func write(_ history: WorkflowHistory, days: Double, state: String = "completed") throws -> URL {
    let id = UUID()
    let date = now.addingTimeInterval(-days * 86400)
    let directory = history.storage.directory(root: URL(filePath: "/project"), createdAt: date, runID: id)
    try history.storage.prepare(directory)
    let object: [String: Any] = [
      "version": 1,
      "run": ["id": id.uuidString, "workflow_name": "Test", "status": ["state": state],
              "started_at": date.ISO8601Format(), "finished_at": date.ISO8601Format()],
      "worktree": ["path": "/project"],
    ]
    try JSONSerialization.data(withJSONObject: object).write(to: directory.appending(path: "run.json"))
    try Data("artifact".utf8).write(to: directory.appending(path: "output.md"))
    return directory
  }
}
