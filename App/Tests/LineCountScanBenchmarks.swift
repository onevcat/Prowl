import Foundation
import Testing

@testable import supacode

extension PerformanceBenchmarks {
  /// Pins the #644/#652 untracked line-count scanner against the pre-#644
  /// `Data.reduce` reader it replaced. Two shapes matter: sparse text is where
  /// `memchr` wins, and newline-dense input is where pure `memchr` regressed
  /// past the original until the hybrid raw-pointer fallback bounded it.
  @Suite
  struct LineCountScanBenchmarks {
    @Test func scannerOutpacesTheReduceReaderOnSparseText() throws {
      try assertScannerBeatsReference(
        data: Self.sparseText(byteCount: Self.inputByteCount),
        name: "sparse",
        minimumRatio: 3
      )
    }

    /// Optimized builds only: the dense case is a race between two Swift-level
    /// loops (the hybrid's raw-pointer fallback vs `Data.Iterator`), and under
    /// `-Onone` the fallback loses — see `BenchmarkMeasurement.isOptimizedBuild`.
    @Test(.enabled(if: BenchmarkMeasurement.isOptimizedBuild))
    func scannerStaysAheadOfTheReduceReaderOnAllNewlineInput() throws {
      try assertScannerBeatsReference(
        data: Data(repeating: 0x0A, count: Self.inputByteCount),
        name: "all-newline",
        minimumRatio: 2
      )
    }

    private func assertScannerBeatsReference(data: Data, name: String, minimumRatio: Double) throws {
      let fileManager = FileManager.default
      let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? fileManager.removeItem(at: tempRoot) }
      try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
      try data.write(to: tempRoot.appending(path: "input.txt"))

      // Both implementations must agree before their speed is compared.
      let shippedCount = GitClient.countLinesInFiles(
        ["input.txt"],
        relativeTo: tempRoot,
        cache: UntrackedLineCountCache()
      )
      let referenceCount = Self.referenceCountLines(in: tempRoot.appending(path: "input.txt"))
      #expect(shippedCount.skippedFileCount == 0)
      #expect(shippedCount.lines == referenceCount)

      let medians = BenchmarkMeasurement.interleavedMedians(
        reference: {
          _ = Self.referenceCountLines(in: tempRoot.appending(path: "input.txt"))
        },
        shipped: {
          // A fresh cache each round keeps this a scan benchmark; the cached
          // path is pinned separately by the byte-budget proxy tests.
          _ = GitClient.countLinesInFiles(
            ["input.txt"],
            relativeTo: tempRoot,
            cache: UntrackedLineCountCache()
          )
        }
      )
      BenchmarkMeasurement.report(suite: "LineCountScan", name: name, medians: medians)
      #expect(
        BenchmarkMeasurement.ratio(medians) >= minimumRatio,
        "shipped scanner was only \(BenchmarkMeasurement.ratio(medians))x the reduce reader on \(name)"
      )
    }

    private static var inputByteCount: Int {
      (BenchmarkMeasurement.isFullMode ? 2_048 : 256) * 1_024
    }

    /// Text shaped like a `sample(1)` capture — the workload #644 was written
    /// against: moderate lines, leading indentation, pure ASCII.
    private static func sparseText(byteCount: Int) -> Data {
      var out = Data(capacity: byteCount + 128)
      var lineNumber = 0
      while out.count < byteCount {
        let indent = String(repeating: " ", count: 4 + (lineNumber % 5) * 2)
        let line = "\(indent)\(1_200 + lineNumber % 800) Thread_\(90_000 + lineNumber)   com.apple.main-thread\n"
        out.append(Data(line.utf8))
        lineNumber += 1
      }
      return out.prefix(byteCount)
    }

    /// The pre-#644 reader, verbatim: 64 KiB chunks walked through
    /// `Data.Iterator` with a value-witness call per byte.
    private static func referenceCountLines(in fileURL: URL) -> Int? {
      guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
      defer { try? handle.close() }

      let binaryProbeByteCount = 8_192
      let chunkByteCount = 64 * 1_024
      var probedByteCount = 0
      var lineCount = 0
      var isEmpty = true
      var lastByte: UInt8?

      while true {
        guard let chunk = try? handle.read(upToCount: chunkByteCount), !chunk.isEmpty else { break }
        isEmpty = false
        if probedByteCount < binaryProbeByteCount {
          let remainingProbeCount = binaryProbeByteCount - probedByteCount
          let probe = chunk.prefix(remainingProbeCount)
          if probe.contains(0x00) { return nil }
          probedByteCount += probe.count
        }
        lineCount += chunk.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        lastByte = chunk.last
      }

      if !isEmpty, lastByte != 0x0A {
        lineCount += 1
      }
      return lineCount
    }
  }
}
