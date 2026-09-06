// supacode/CLIService/SendCommandHandler.swift
// Handles `prowl send` by resolving target, delivering text, and optionally waiting.

import Foundation
import ProwlCLIShared

private let sendLogger = SupaLogger("SendCommandHandler")

/// Resolved target metadata for payload construction (no live view reference).
struct SendResolvedTarget: Sendable {
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

extension SendResolvedTarget {
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
struct CLISendTextDelivery {
  typealias InsertText = @MainActor (UUID, String) -> Bool
  typealias SubmitLine = @MainActor (UUID) -> Bool

  let insertText: InsertText
  let submitLine: SubmitLine

  func deliver(to target: SendResolvedTarget, text: String, trailingEnter: Bool) {
    _ = insertText(target.paneID, text)
    if trailingEnter {
      _ = submitLine(target.paneID)
    }
  }
}

@MainActor
final class SendCommandHandler: CommandHandler {
  typealias ResolveProvider = @MainActor (TargetSelector) -> Result<SendResolvedTarget, TargetResolverError>
  typealias TextDelivery = @MainActor (SendResolvedTarget, String, Bool) -> Void
  typealias WaiterProvider = @MainActor (String, UUID) -> AsyncStream<(exitCode: Int?, durationMs: Int)>?
  typealias CaptureProvider = @MainActor (SendResolvedTarget) -> ReadCaptureInput?

  private let resolveProvider: ResolveProvider
  private let textDelivery: TextDelivery
  private let waiterProvider: WaiterProvider
  private let captureProvider: CaptureProvider?

  init(
    resolveProvider: @escaping ResolveProvider,
    textDelivery: @escaping TextDelivery,
    waiterProvider: @escaping WaiterProvider,
    captureProvider: CaptureProvider? = nil
  ) {
    self.resolveProvider = resolveProvider
    self.textDelivery = textDelivery
    self.waiterProvider = waiterProvider
    self.captureProvider = captureProvider
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    guard case .send(let input) = envelope.command else {
      return errorResponse(code: CLIErrorCode.sendFailed, message: "Invalid command.")
    }

    // Validate capture constraints
    if input.captureOutput {
      if !input.wait {
        return errorResponse(
          code: CLIErrorCode.invalidArgument,
          message: "--capture requires waiting for command completion."
        )
      }
      if !input.trailingEnter {
        return errorResponse(
          code: CLIErrorCode.invalidArgument,
          message: "--capture requires a trailing Enter to run the command."
        )
      }
    }

    // Resolve target
    let result = resolveProvider(input.selector)
    let target: SendResolvedTarget
    switch result {
    case .success(let resolved):
      target = resolved
    case .failure(let error):
      return mapResolverError(error)
    }

    let waitStream = input.wait ? waiterProvider(target.worktreeID, target.paneID) : nil

    // If capture is requested but the pane has no shell integration (no wait stream),
    // reject early with CAPTURE_UNSUPPORTED — do not send text and fall through to timeout.
    if input.captureOutput && waitStream == nil {
      return errorResponse(
        code: CLIErrorCode.captureUnsupported,
        message: "--capture requires shell integration (OSC 133) on the target pane. "
          + "This pane does not appear to support it."
      )
    }

    // Pre-capture snapshot (before text delivery)
    let preCapture: ReadCaptureInput? = input.captureOutput ? captureProvider?(target) : nil

    // Deliver text (and optional Enter)
    textDelivery(target, input.text, input.trailingEnter)

    // Wait for command completion if requested
    let waitResult: SendWaitResult?
    if input.wait {
      waitResult = await waitForCompletion(
        stream: waitStream,
        timeoutSeconds: input.timeoutSeconds ?? 30
      )
      if waitResult == nil {
        return errorResponse(
          code: CLIErrorCode.waitTimeout,
          message: "Timed out waiting for command to finish. "
            + "This may happen if the terminal does not have shell integration (OSC 133) enabled."
        )
      }
    } else {
      waitResult = nil
    }

    // Post-capture snapshot (after completion) and diff
    let capturedOutput: CapturedOutput?
    if input.captureOutput {
      if let pre = preCapture, let post = captureProvider?(target) {
        capturedOutput = diffCapture(pre: pre, post: post, commandText: input.text)
      } else {
        capturedOutput = nil
      }
    } else {
      capturedOutput = nil
    }

    // Build payload
    let payload = SendCommandPayload(
      target: makePayloadTarget(from: target),
      input: SendInputInfo(
        source: input.source.rawValue,
        characters: input.text.unicodeScalars.count,
        bytes: input.text.utf8.count,
        trailingEnterSent: input.trailingEnter
      ),
      createdTab: false,
      wait: waitResult,
      capture: capturedOutput
    )

    do {
      return try CommandResponse(
        ok: true,
        command: "send",
        schemaVersion: "prowl.cli.send.v1",
        data: RawJSON(encoding: payload)
      )
    } catch {
      sendLogger.warning("Failed to encode send payload: \(error)")
      return errorResponse(code: CLIErrorCode.sendFailed, message: "Failed to encode response.")
    }
  }

  // MARK: - Capture Diff

  private func diffCapture(pre: ReadCaptureInput, post: ReadCaptureInput, commandText: String) -> CapturedOutput {
    let preText = pre.screenText ?? pre.viewportText
    let postText = post.screenText ?? post.viewportText

    // Trim trailing whitespace-only lines from both snapshots (screen buffer padding)
    let preLines = trimTrailingBlankLines(splitLines(preText))
    let postLines = trimTrailingBlankLines(splitLines(postText))

    // If post has fewer lines than pre, the screen was cleared — return all of post as truncated
    if postLines.count < preLines.count {
      let text = postText
      let count = postLines.isEmpty ? 0 : postLines.count
      return CapturedOutput(text: text, lineCount: count, source: .screenDiff, truncated: true)
    }

    // Find common prefix length
    let commonPrefixLength = zip(preLines, postLines).prefix(while: { $0 == $1 }).count

    // New lines are everything after the common prefix in post
    var newLines = Array(postLines.dropFirst(commonPrefixLength))

    // Strip echoed command line: if first new line matches command (trimmed) or ends with it (e.g. "$ cmd")
    let trimmedCommand = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
    if let first = newLines.first {
      let firstStr = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
      if firstStr == trimmedCommand || firstStr.hasSuffix(trimmedCommand) {
        newLines = Array(newLines.dropFirst())
      }
    }

    // Strip trailing prompt line: if the last new line matches the last line of pre (e.g. "$ "),
    // remove it once — it's the new prompt after the command finished.
    if let lastPre = preLines.last, let lastNew = newLines.last, lastNew == lastPre {
      newLines = Array(newLines.dropLast())
    }

    // Trim trailing empty lines (screen buffer padding / blank lines after output)
    while let last = newLines.last, String(last).trimmingCharacters(in: .whitespaces).isEmpty {
      newLines = Array(newLines.dropLast())
    }

    if newLines.isEmpty {
      return CapturedOutput(text: "", lineCount: 0, source: .screenDiff, truncated: false)
    }

    let resultText = newLines.map(String.init).joined(separator: "\n")
    return CapturedOutput(text: resultText, lineCount: newLines.count, source: .screenDiff, truncated: false)
  }

  private func splitLines(_ text: String) -> [Substring] {
    guard !text.isEmpty else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
  }

  private func trimTrailingBlankLines(_ lines: [Substring]) -> [Substring] {
    var result = lines
    while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      result.removeLast()
    }
    return result
  }

  // MARK: - Wait

  private func waitForCompletion(
    stream: AsyncStream<(exitCode: Int?, durationMs: Int)>?,
    timeoutSeconds: Int
  ) async -> SendWaitResult? {
    guard let stream else {
      return nil
    }

    // Race stream result against timeout using raw tuples (Sendable-safe).
    let raw: (exitCode: Int?, durationMs: Int)? = await withTaskGroup(
      of: (Int?, Int)?.self
    ) { group in
      group.addTask {
        for await result in stream {
          return (result.exitCode, result.durationMs)
        }
        return nil
      }

      group.addTask {
        try? await Task.sleep(for: .seconds(timeoutSeconds))
        return nil
      }

      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }

    guard let raw else { return nil }
    return SendWaitResult(exitCode: raw.exitCode, durationMs: raw.durationMs)
  }

  // MARK: - Helpers

  private func makePayloadTarget(from target: SendResolvedTarget) -> SendTarget {
    SendTarget(
      worktree: SendTargetWorktree(
        id: target.worktreeID,
        name: target.worktreeName,
        path: target.worktreePath,
        rootPath: target.worktreeRootPath,
        kind: target.worktreeKind.rawValue
      ),
      tab: SendTargetTab(
        id: target.tabID.uuidString,
        title: target.tabTitle,
        selected: target.tabSelected
      ),
      pane: SendTargetPane(
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
      command: "send",
      schemaVersion: "prowl.cli.send.v1",
      error: CommandError(code: code, message: message)
    )
  }
}
