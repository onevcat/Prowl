import Foundation
import Synchronization
import Testing

@testable import Prowl

struct MirrorJSONLineReaderTests {
  @Test func joinsPartialLinesAndStripsCarriageReturns() {
    var reader = MirrorJSONLineReader()
    #expect(reader.append(Data("{\"a\":1}\n{\"b\"".utf8)).map(text) == ["{\"a\":1}"])
    #expect(reader.append(Data(":2}\r\n\n".utf8)).map(text) == ["{\"b\":2}"])
    #expect(reader.append(Data("{\"c\":3}".utf8)).isEmpty)
    #expect(reader.append(Data("\n".utf8)).map(text) == ["{\"c\":3}"])
  }

  @Test func dropsOversizedLinesWhole() {
    var reader = MirrorJSONLineReader()
    reader.maximumLineBytes = 8
    #expect(reader.append(Data("0123456789".utf8)).isEmpty)
    #expect(reader.append(Data("abc\nok\n".utf8)).map(text) == ["ok"])
    #expect(reader.droppedLines == 1)
    #expect(reader.append(Data("0123456789\nfine\n".utf8)).map(text) == ["fine"])
    #expect(reader.droppedLines == 2)
  }

  @Test func discardsAPartialFirstLine() {
    var reader = MirrorJSONLineReader()
    reader.discardPartialFirstLine()
    #expect(reader.append(Data("tail of record}\n{\"x\":1}\n".utf8)).map(text) == ["{\"x\":1}"])
  }
}

struct MirrorTranscriptTailTests {
  private nonisolated final class Changes: Sendable {
    private let storage = Mutex<[MirrorTranscriptTail.Change]>([])
    func record(_ change: MirrorTranscriptTail.Change) { storage.withLock { $0.append(change) } }
    var all: [MirrorTranscriptTail.Change] { storage.withLock { $0 } }
    var labels: [String] {
      all.map { change in
        switch change {
        case .replay(let data, let head, let mid):
          "replay:\(text(data))\(head.map { ":head=" + text($0) } ?? "")\(mid ? ":mid" : "")"
        case .appended(let data): "appended:\(text(data))"
        case .rotated: "rotated"
        case .missing: "missing"
        }
      }
    }
  }

  private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "mirror-tail-\(UUID().uuidString).jsonl")
  }

  private func makeTail(_ url: URL, replayLimit: Int = 1 << 20) -> (MirrorTranscriptTail, Changes) {
    let changes = Changes()
    let options = MirrorTranscriptTail.Options(replayLimitBytes: replayLimit, pollInterval: .milliseconds(50))
    let tail = MirrorTranscriptTail(url: url, queue: DispatchQueue(label: "tail-test"), options: options) {
      changes.record($0)
    }
    return (tail, changes)
  }

  private func append(_ string: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(string.utf8))
    try handle.close()
  }

  @Test func replaysThenFollowsAppends() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("one\ntwo\n".utf8).write(to: url)
    let (tail, changes) = makeTail(url)
    tail.start()
    await waitUntil { changes.all.count >= 1 }
    #expect(changes.labels == ["replay:one\ntwo\n"])
    try append("three\n", to: url)
    await waitUntil { changes.all.count >= 2 }
    #expect(changes.labels.last == "appended:three\n")
    tail.stop()
  }

  @Test func reportsRotationAndReplaysTheReplacement() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("old-1\nold-2\n".utf8).write(to: url)
    let (tail, changes) = makeTail(url)
    tail.start()
    await waitUntil { changes.all.count >= 1 }
    try FileManager.default.removeItem(at: url)
    try Data("new\n".utf8).write(to: url, options: .atomic)
    // The delete event can arrive before the replacement exists, which adds a `missing` in between.
    await waitUntil(timeout: .seconds(5)) { changes.labels.last == "replay:new\n" }
    let labels = changes.labels
    #expect(labels.last == "replay:new\n")
    #expect(labels.first == "replay:old-1\nold-2\n" && labels.contains("rotated") && labels.count <= 4)
    tail.stop()
  }

  @Test(arguments: ["re\n", "rewrite\n", "rewritten-longer\n"])
  func sameInodeTruncateAndRewriteIsRotated(replacement: String) async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("initial\n".utf8).write(to: url)
    let (tail, changes) = makeTail(url)
    tail.start()
    await waitUntil { changes.all.count >= 1 }
    // Truncate and rewrite the same file: the size may end below, at, or above the old offset.
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data(replacement.utf8))
    try handle.close()
    await waitUntil(timeout: .seconds(5)) { changes.labels.last == "replay:\(replacement)" }
    #expect(changes.labels == ["replay:initial\n", "rotated", "replay:\(replacement)"])
    tail.stop()
  }

  @Test func waitsForAMissingFile() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let (tail, changes) = makeTail(url)
    tail.start()
    await waitUntil { changes.all.count >= 1 }
    #expect(changes.labels == ["missing"])
    try Data("here\n".utf8).write(to: url, options: .atomic)
    await waitUntil { changes.all.count >= 2 }
    #expect(changes.labels == ["missing", "replay:here\n"])
    tail.stop()
  }

  @Test func boundsTheReplayWithTheHeadAndMarksAMidRecordStart() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("0123456789\nabcdef\n".utf8).write(to: url)
    let (tail, changes) = makeTail(url, replayLimit: 10)
    tail.start()
    await waitUntil { changes.all.count >= 1 }
    #expect(changes.labels == ["replay:89\nabcdef\n:head=0123456789\nabcdef\n:mid"])
    tail.stop()
  }

  @Test func aWindowStartingAfterANewlineIsNotMidRecord() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("0123456789\nabcdef\n".utf8).write(to: url)
    let (tail, changes) = makeTail(url, replayLimit: 7)
    tail.start()
    await waitUntil { changes.all.count >= 1 }
    #expect(changes.labels == ["replay:abcdef\n:head=0123456789\nabcdef\n"])
    tail.stop()
  }
}

/// Lint prefers the failable conversion; test fixtures are always UTF-8.
private nonisolated func text(_ data: Data) -> String {
  String(bytes: data, encoding: .utf8) ?? ""
}
