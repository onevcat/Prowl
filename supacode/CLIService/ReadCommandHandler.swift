// supacode/CLIService/ReadCommandHandler.swift
// Handles `prowl read` by resolving target and reading snapshot/last text.

import Foundation
import ProwlCLIShared

private struct ReadCapture {
  let text: String
  let source: ReadSource
  let truncated: Bool
}

struct ReadCaptureRequest: Sendable {
  let target: ReadResolvedTarget
  let source: ReadInputSource
}

struct ReadCaptureInput: Sendable {
  enum Content: Sendable {
    case viewport(text: String, screenText: String?)
    case detection(text: String)
  }

  let content: Content

  var viewportText: String {
    switch content {
    case .viewport(let text, _), .detection(let text): text
    }
  }

  var screenText: String? {
    switch content {
    case .viewport(_, let screenText): screenText
    case .detection: nil
    }
  }

  init(viewportText: String, screenText: String?) {
    self.content = .viewport(text: viewportText, screenText: screenText)
  }

  init(detectionText: String) {
    self.content = .detection(text: detectionText)
  }
}

/// Resolved target metadata for read payload construction.
struct ReadResolvedTarget: Sendable {
  let worktreeID: String
  let worktreeName: String
  let worktreePath: String
  let worktreeRootPath: String
  let worktreeKind: ListCommandWorktree.Kind
  let tabID: UUID
  let tabTitle: String
  let tabSelected: Bool
  let paneID: UUID
  let paneTitle: String
  let paneCWD: String?
  let paneFocused: Bool
}

extension ReadResolvedTarget {
  init(from resolved: ResolvedTarget) {
    self.worktreeID = resolved.worktreeID
    self.worktreeName = resolved.worktreeName
    self.worktreePath = resolved.worktreePath
    self.worktreeRootPath = resolved.worktreeRootPath
    self.worktreeKind = resolved.worktreeKind
    self.tabID = resolved.tabID
    self.tabTitle = resolved.tabTitle
    self.tabSelected = resolved.tabSelected
    self.paneID = resolved.paneID
    self.paneTitle = resolved.paneTitle
    self.paneCWD = resolved.paneCWD
    self.paneFocused = resolved.paneFocused
  }
}

@MainActor
final class ReadCommandHandler: CommandHandler {
  typealias ResolveProvider = @MainActor (TargetSelector) -> Result<ReadResolvedTarget, TargetResolverError>
  typealias CaptureProvider = @MainActor (ReadCaptureRequest) -> ReadCaptureInput?

  private let resolveProvider: ResolveProvider
  private let captureProvider: CaptureProvider
  private let clock: any Clock<Duration>

  init(
    resolveProvider: @escaping ResolveProvider,
    captureProvider: @escaping CaptureProvider,
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.resolveProvider = resolveProvider
    self.captureProvider = captureProvider
    self.clock = clock
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    guard case .read(let input) = envelope.command else {
      return errorResponse(code: CLIErrorCode.readFailed, message: "Invalid command.")
    }

    let target: ReadResolvedTarget
    switch resolveProvider(input.selector) {
    case .success(let resolved):
      target = resolved
    case .failure(let error):
      return mapResolverError(error)
    }

    let capture: ReadCapture
    let stabilized: Bool?
    let waitedMs: Int?
    let samples: Int?
    if input.waitStable {
      guard let result = await pollUntilStable(target: target, input: input) else {
        return errorResponse(code: CLIErrorCode.readFailed, message: "Failed to read terminal text.")
      }
      capture = result.capture
      stabilized = result.stabilized
      waitedMs = result.waitedMs
      samples = result.samples
    } else {
      guard let single = makeCapture(target: target, input: input) else {
        return errorResponse(code: CLIErrorCode.readFailed, message: "Failed to read terminal text.")
      }
      capture = single
      stabilized = nil
      waitedMs = nil
      samples = nil
    }

    let payload = ReadCommandPayload(
      target: makePayloadTarget(from: target),
      mode: input.last == nil ? .snapshot : .last,
      last: input.last,
      source: capture.source,
      truncated: capture.truncated,
      lineCount: lineCount(in: capture.text),
      text: capture.text,
      stabilized: stabilized,
      waitedMs: waitedMs,
      samples: samples
    )

    do {
      return try CommandResponse(
        ok: true,
        command: "read",
        schemaVersion: "prowl.cli.read.v1",
        data: RawJSON(encoding: payload)
      )
    } catch {
      return errorResponse(code: CLIErrorCode.readFailed, message: "Failed to encode response.")
    }
  }

  private struct StableResult {
    let capture: ReadCapture
    let stabilized: Bool
    let waitedMs: Int
    let samples: Int
  }

  /// Default stability tuning, applied when the request omits the corresponding value.
  private enum StabilityDefaults {
    static let intervalMs = 200
    static let periodMs = 800
    static let timeoutSeconds = 10
  }

  /// Capture the requested terminal source, applying `--last` line selection when requested.
  private func makeCapture(target: ReadResolvedTarget, input: ReadInput) -> ReadCapture? {
    let request = ReadCaptureRequest(target: target, source: input.source)
    guard let captureInput = captureProvider(request) else { return nil }

    switch (input.source, captureInput.content) {
    case (.viewport, .viewport(let viewportText, let screenText)):
      if let last = input.last {
        return captureLast(
          requestedLineCount: last,
          viewportText: viewportText,
          screenText: screenText
        )
      }
      return ReadCapture(
        text: viewportText,
        source: .screen,
        truncated: false
      )

    case (.detection, .detection(let text)):
      let output: String
      if let last = input.last {
        output = joinLines(splitLines(text).suffix(last))
      } else {
        output = text
      }
      return ReadCapture(
        text: output,
        source: .detection,
        truncated: false
      )

    default:
      return nil
    }
  }

  /// Re-read the pane on a fixed interval until its content stops changing for a streak of
  /// consecutive samples (≈ `period`), or until the timeout caps the total number of samples.
  /// Returns the latest capture either way, flagging whether it actually stabilized.
  private func pollUntilStable(target: ReadResolvedTarget, input: ReadInput) async -> StableResult? {
    let intervalMs = input.stableIntervalMs ?? StabilityDefaults.intervalMs
    let periodMs = input.stablePeriodMs ?? StabilityDefaults.periodMs
    let timeoutMs = (input.waitTimeoutSeconds ?? StabilityDefaults.timeoutSeconds) * 1000
    let interval = Duration.milliseconds(intervalMs)

    // Consecutive unchanged samples that together cover `period`, and the hard cap from `timeout`.
    let requiredStreak = max(1, Int((Double(periodMs) / Double(intervalMs)).rounded(.up)))
    let maxSleeps = max(1, Int((Double(timeoutMs) / Double(intervalMs)).rounded(.up)))

    guard var current = makeCapture(target: target, input: input) else { return nil }
    var streak = 0
    var samples = 1
    var sleeps = 0
    var stabilized = false

    while true {
      if streak >= requiredStreak {
        stabilized = true
        break
      }
      if sleeps >= maxSleeps {
        stabilized = false
        break
      }
      do {
        try await clock.sleep(for: interval)
      } catch {
        break  // Cancelled: return the best capture so far.
      }
      sleeps += 1
      guard let next = makeCapture(target: target, input: input) else {
        break  // Capture became unavailable mid-poll (e.g. pane closed): stop with what we have.
      }
      samples += 1
      if next.text == current.text {
        streak += 1
      } else {
        current = next
        streak = 0
      }
    }

    return StableResult(
      capture: current,
      stabilized: stabilized,
      waitedMs: sleeps * intervalMs,
      samples: samples
    )
  }

  private func captureLast(
    requestedLineCount: Int,
    viewportText: String,
    screenText: String?
  ) -> ReadCapture {
    let viewportLines = splitLines(viewportText)
    if viewportLines.count >= requestedLineCount {
      let text = joinLines(viewportLines.suffix(requestedLineCount))
      return ReadCapture(
        text: text,
        source: .screen,
        truncated: false
      )
    }

    guard let screenText else {
      // The full screen+scrollback buffer could not be read, so we only have the visible
      // viewport. If it holds fewer lines than requested, older history may exist beyond our
      // reach — the result may be incomplete, which is exactly what `truncated` should signal.
      return ReadCapture(
        text: joinLines(viewportLines.suffix(min(requestedLineCount, viewportLines.count))),
        source: .mixed,
        truncated: viewportLines.count < requestedLineCount
      )
    }

    let screenLines = splitLines(screenText)
    if screenLines.count < viewportLines.count {
      // The full-buffer read returned fewer lines than the viewport itself — an unreliable
      // capture. We fall back to the viewport and, as above, cannot vouch for completeness
      // when it is shorter than requested.
      return ReadCapture(
        text: joinLines(viewportLines.suffix(min(requestedLineCount, viewportLines.count))),
        source: .mixed,
        truncated: viewportLines.count < requestedLineCount
      )
    }

    let source: ReadSource = screenLines.count > viewportLines.count ? .scrollback : .screen
    let text = joinLines(screenLines.suffix(min(requestedLineCount, screenLines.count)))

    // The full screen+scrollback buffer was retrievable, so `text` already holds every line
    // the pane retains. Returning fewer lines than `--last` requested here only means the
    // pane has less history than asked for — not that content was lost — so it is complete,
    // not truncated. `truncated` stays reserved for cases where content may be unreachable
    // (see the viewport-only fallbacks above).
    return ReadCapture(
      text: text,
      source: source,
      truncated: false
    )
  }

  private func splitLines(_ text: String) -> [Substring] {
    guard !text.isEmpty else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
  }

  private func joinLines(_ lines: ArraySlice<Substring>) -> String {
    lines.map(String.init).joined(separator: "\n")
  }

  private func lineCount(in text: String) -> Int {
    splitLines(text).count
  }

  private func makePayloadTarget(from target: ReadResolvedTarget) -> ReadTarget {
    ReadTarget(
      worktree: ReadTargetWorktree(
        id: target.worktreeID,
        name: target.worktreeName,
        path: target.worktreePath,
        rootPath: target.worktreeRootPath,
        kind: target.worktreeKind.rawValue
      ),
      tab: ReadTargetTab(
        id: target.tabID.uuidString,
        title: target.tabTitle,
        selected: target.tabSelected
      ),
      pane: ReadTargetPane(
        id: target.paneID.uuidString,
        title: target.paneTitle,
        cwd: target.paneCWD,
        focused: target.paneFocused
      )
    )
  }

  private func mapResolverError(_ error: TargetResolverError) -> CommandResponse {
    switch error {
    case .notFound(let message):
      return errorResponse(code: CLIErrorCode.targetNotFound, message: message)
    case .notUnique(let message):
      return errorResponse(code: CLIErrorCode.targetNotUnique, message: message)
    }
  }

  private func errorResponse(code: String, message: String) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: "read",
      schemaVersion: "prowl.cli.read.v1",
      error: CommandError(code: code, message: message)
    )
  }
}
