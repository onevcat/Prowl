import Foundation
import Testing

@testable import Prowl

extension PerformanceBenchmarks {
  /// Pins the transcript line splitter that a Mirror chat replays on open against the reader
  /// it replaced, which removed each line from the front of the buffer. That copied the rest of
  /// a 32 MB replay window once per line: 4.9 s for a 36.7 MB Claude transcript, measured on
  /// the Host before the phone saw the chat.
  @Suite
  struct MirrorTranscriptLineBenchmarks {
    /// The slow side is a `memmove` per line, so the ratio holds in Debug builds too.
    @Test func splittingAReplayIsLinear() {
      let data = Self.transcript(byteCount: Self.inputByteCount)

      var shippedReader = MirrorJSONLineReader()
      let shipped = shippedReader.append(data)
      #expect(shipped == Self.referenceLines(data))
      #expect(shipped.count == Self.lineCount(byteCount: Self.inputByteCount))

      let medians = BenchmarkMeasurement.interleavedMedians(
        reference: { _ = Self.referenceLines(data) },
        shipped: {
          var reader = MirrorJSONLineReader()
          _ = reader.append(data)
        }
      )
      BenchmarkMeasurement.report(suite: "MirrorTranscriptLines", name: "replay", medians: medians)
      // The old reader is quadratic, so the gap grows with the input: about 5x at the 8 MB Debug
      // size, far more at the 32 MB replay window that `make bench` uses.
      #expect(
        BenchmarkMeasurement.ratio(medians) >= (BenchmarkMeasurement.isFullMode ? 20 : 3),
        "the line reader was only \(BenchmarkMeasurement.ratio(medians))x the front-removing reader"
      )
    }

    private static var inputByteCount: Int {
      (BenchmarkMeasurement.isFullMode ? 32 : 8) * 1_024 * 1_024
    }

    private static let lineBytes = 3_400

    private static func lineCount(byteCount: Int) -> Int { byteCount / lineBytes }

    /// JSONL lines about as long as a Claude transcript's average record.
    private static func transcript(byteCount: Int) -> Data {
      let prefix = "{\"type\":\"assistant\",\"text\":\""
      let suffix = "\"}\n"
      let line = Data(
        (prefix + String(repeating: "x", count: lineBytes - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
      var out = Data(capacity: byteCount)
      for _ in 0..<lineCount(byteCount: byteCount) { out.append(line) }
      return out
    }

    /// The reader before this fix, without the oversized-line handling the input never needs.
    private static func referenceLines(_ data: Data) -> [Data] {
      var buffer = data
      var lines: [Data] = []
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        if !line.isEmpty { lines.append(line) }
      }
      return lines
    }
  }
}
