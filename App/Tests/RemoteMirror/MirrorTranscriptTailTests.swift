import Foundation
import Synchronization
import Testing

@testable import Prowl

struct MirrorJSONLineReaderTests {
  @Test func joinsPartialLinesAndStripsCarriageReturns() {
    var reader = MirrorJSONLineReader()
    #expect(reader.append(Data("{\"a\":1}\n{\"b\"".utf8)).map { text($0) } == ["{\"a\":1}"])
    #expect(reader.append(Data(":2}\r\n\n".utf8)).map { text($0) } == ["{\"b\":2}"])
    #expect(reader.append(Data("{\"c\":3}".utf8)).isEmpty)
    #expect(reader.append(Data("\n".utf8)).map { text($0) } == ["{\"c\":3}"])
  }

  @Test func dropsOversizedLinesWhole() {
    var reader = MirrorJSONLineReader()
    reader.maximumLineBytes = 8
    #expect(reader.append(Data("0123456789".utf8)).isEmpty)
    #expect(reader.append(Data("abc\nok\n".utf8)).map { text($0) } == ["ok"])
    #expect(reader.droppedLines == 1)
    #expect(reader.append(Data("0123456789\nfine\n".utf8)).map { text($0) } == ["fine"])
    #expect(reader.droppedLines == 2)
  }

  @Test func discardsAPartialFirstLine() {
    var reader = MirrorJSONLineReader()
    reader.discardPartialFirstLine()
    #expect(
      reader.append(Data("tail of record}\n{\"x\":1}\n".utf8)).map { text($0) } == [
        "{\"x\":1}"
      ])
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
        case .replay(let data, let mid): "replay:\(text(data))\(mid ? ":mid" : "")"
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

  @Test func replaysThenFollowsAppends() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("one\ntwo\n".utf8).write(to: url)
    let (tail, changes) = makeTail(url)
    tail.start()
    await waitUntil { changes.all.count >= 1 }
    #expect(changes.labels == ["replay:one\ntwo\n"])
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("three\n".utf8))
    try handle.close()
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
    try Data("new\n".utf8).write(to: url)
    // The delete event can arrive before the replacement exists, which adds a `missing` in between.
    await waitUntil(timeout: .seconds(5)) { changes.labels.last == "replay:new\n" }
    let labels = changes.labels
    #expect(labels.last == "replay:new\n")
    #expect(labels.first == "replay:old-1\nold-2\n" && labels.contains("rotated") && labels.count <= 4)
    tail.stop()
  }

  @Test func waitsForAMissingFile() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let (tail, changes) = makeTail(url)
    tail.start()
    await waitUntil { changes.all.count >= 1 }
    #expect(changes.labels == ["missing"])
    try Data("here\n".utf8).write(to: url)
    await waitUntil { changes.all.count >= 2 }
    #expect(changes.labels == ["missing", "replay:here\n"])
    tail.stop()
  }

  @Test func boundsTheReplayAndMarksAMidRecordStart() async throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("0123456789\nabcdef\n".utf8).write(to: url)
    let (tail, changes) = makeTail(url, replayLimit: 10)
    tail.start()
    await waitUntil { changes.all.count >= 1 }
    #expect(changes.labels == ["replay:89\nabcdef\n:mid"])
    tail.stop()
  }
}

/// Lint prefers the failable conversion; test fixtures are always UTF-8.
private nonisolated func text(_ data: Data) -> String {
  String(bytes: data, encoding: .utf8) ?? ""
}
