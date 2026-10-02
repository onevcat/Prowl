import Foundation
import Testing

@testable import supacode

/// Root suite for the timed benchmarks that pin the hot paths optimized in the
/// #644–#665 performance wave against the naive implementations they replaced.
///
/// Assertions are ratios, never absolute times: reference and shipped bodies run
/// interleaved in one process, so machine speed and background load cancel out.
/// Thresholds sit far below the ratios measured in a Release build, which is
/// what keeps the default Debug test run from flaking. Serialized recursively
/// because two timing suites running concurrently would distort each other's
/// medians in a way interleaving cannot compensate for.
///
/// `make bench` runs this suite alone with `-O` and `PROWL_BENCH_REPORT=1`,
/// switching to full-size inputs and appending absolute medians to the bench
/// log — the durable per-machine time series the ratio assertions never read.
@Suite(.serialized)
struct PerformanceBenchmarks {}

nonisolated enum BenchmarkMeasurement {
  /// Full mode uses input sizes comparable to the docs-ai/056 baselines and
  /// reports absolute numbers; the default sizes keep the Debug-mode run short.
  static var isFullMode: Bool {
    ProcessInfo.processInfo.environment["PROWL_BENCH_REPORT"] == "1"
  }

  static var iterations: Int { isFullMode ? 15 : 5 }

  /// True in `-O` builds: `assert` bodies execute only under `-Onone`. This is
  /// what distinguishes `make bench` from the regular Debug test run — `DEBUG`
  /// stays defined in both, so a compilation condition cannot tell them apart.
  ///
  /// Ratios whose slow side is a C call (`memchr`, filesystem I/O) hold in any
  /// build mode; ratios between two Swift-level formulations only mean anything
  /// once both sides are optimized, so those assertions gate on this. Measured
  /// in Debug before gating: the escape-absence guard's own byte scan drops to
  /// 1.13x the regex it guards, and the hybrid scanner's raw-pointer fallback
  /// runs at 0.45x the `Data.reduce` reader it replaced.
  static var isOptimizedBuild: Bool {
    var optimized = true
    assert(
      {
        optimized = false
        return true
      }()
    )
    return optimized
  }

  /// Medians for two bodies measured alternately, so a load spike lands on both
  /// sides of the ratio instead of biasing whichever side it happened to hit.
  static func interleavedMedians(
    reference: () -> Void,
    shipped: () -> Void
  ) -> (reference: Duration, shipped: Duration) {
    // One untimed round faults in file caches and lazy runtime state.
    reference()
    shipped()
    var referenceTimes: [Duration] = []
    var shippedTimes: [Duration] = []
    for _ in 0..<iterations {
      referenceTimes.append(time(reference))
      shippedTimes.append(time(shipped))
    }
    return (median(referenceTimes), median(shippedTimes))
  }

  static func repeatedMedian(_ body: () -> Void) -> Duration {
    body()
    return median((0..<iterations).map { _ in time(body) })
  }

  static func time(_ body: () -> Void) -> Duration {
    let start = ContinuousClock.now
    body()
    return ContinuousClock.now - start
  }

  static func median(_ values: [Duration]) -> Duration {
    values.sorted()[values.count / 2]
  }

  static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
  }

  static func ratio(_ medians: (reference: Duration, shipped: Duration)) -> Double {
    milliseconds(medians.reference) / milliseconds(medians.shipped)
  }

  static func reportAbsolute(
    suite: String,
    name: String,
    median: Duration,
    normalizingBy workloadCount: Int = 1
  ) {
    guard isFullMode else { return }
    let environment = ProcessInfo.processInfo.environment
    let record = AbsoluteRecord(
      date: Date.now.ISO8601Format(),
      suite: suite,
      name: name,
      medianMilliseconds: milliseconds(median) / Double(workloadCount),
      normalizationDivisor: workloadCount,
      iterations: iterations,
      gitSHA: environment["PROWL_BENCH_GIT_SHA"]
    )
    write(record)
  }

  /// Appends one measurement to the bench log when running under `make bench`.
  /// JSON lines keyed by git SHA keep the series across commits comparable on
  /// one machine; nothing in the test assertions ever reads this file back.
  static func report(suite: String, name: String, medians: (reference: Duration, shipped: Duration)) {
    guard isFullMode else { return }
    let environment = ProcessInfo.processInfo.environment
    let record = Record(
      date: Date.now.ISO8601Format(),
      suite: suite,
      name: name,
      referenceMilliseconds: milliseconds(medians.reference),
      shippedMilliseconds: milliseconds(medians.shipped),
      ratio: ratio(medians),
      iterations: iterations,
      gitSHA: environment["PROWL_BENCH_GIT_SHA"]
    )
    write(record)
  }

  private static func write(_ record: some Encodable) {
    guard let line = try? JSONEncoder().encode(record) else { return }
    let environment = ProcessInfo.processInfo.environment
    let directory =
      environment["PROWL_BENCH_LOG_DIR"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Logs/Prowl/measurements/bench")
    let logURL = directory.appending(path: "bench.jsonl")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: logURL.path(percentEncoded: false)) {
      FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: line + Data("\n".utf8))
  }

  private struct AbsoluteRecord: Encodable {
    let date: String
    let suite: String
    let name: String
    let medianMilliseconds: Double
    let normalizationDivisor: Int
    let iterations: Int
    let gitSHA: String?
  }

  private struct Record: Encodable {
    let date: String
    let suite: String
    let name: String
    let referenceMilliseconds: Double
    let shippedMilliseconds: Double
    let ratio: Double
    let iterations: Int
    let gitSHA: String?
  }
}
