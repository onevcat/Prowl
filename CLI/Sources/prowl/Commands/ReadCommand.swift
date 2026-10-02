// ProwlCLI/Commands/ReadCommand.swift

import ArgumentParser
import ProwlCLIShared

private enum ReadSourceOption: String, ExpressibleByArgument {
  case viewport
  case detection

  var inputSource: ReadInputSource {
    switch self {
    case .viewport: .viewport
    case .detection: .detection
    }
  }
}

struct ReadCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "read",
    abstract: "Read terminal content from a pane."
  )

  @OptionGroup var selector: SelectorOptions
  @OptionGroup var options: GlobalOptions

  @Option(name: .long, help: "Number of recent lines to read (omit for snapshot).")
  var last: Int?

  @Option(
    name: .long,
    help: "Content source: viewport, or detection for the exact active-screen agent detector input."
  )
  private var source: ReadSourceOption = .viewport

  @Flag(name: .long, help: "Re-read the pane until its output stops changing before returning (good for live TUIs).")
  var waitStable = false

  @Option(
    name: .long,
    help: "Sampling interval in milliseconds while waiting for stable output (50–5000, default: 200)."
  )
  var stableInterval: Int?

  @Option(
    name: .long,
    help: "Output must stay unchanged for this many milliseconds to count as stable (100–60000, default: 800)."
  )
  var stablePeriod: Int?

  @Option(
    name: .long,
    help: "Maximum seconds to keep waiting for stable output (1–300, default: 10)."
  )
  var waitTimeout: Int?

  @Argument(help: "Target pane/tab UUID or worktree id/name/path (auto-resolved).")
  var target: String?

  mutating func run() throws {
    try CLIExecution.run(command: "read", output: options.outputMode, colorEnabled: options.colorEnabled) {
      let sel = try selector.resolve(positionalTarget: target)

      if let n = last, n < 1 {
        throw ExitError(
          code: CLIErrorCode.invalidArgument,
          message: "--last requires a positive integer, got \(n)."
        )
      }

      try validateStabilityOptions()

      let requestedSource = source.inputSource
      let envelope = CommandEnvelope(
        output: options.outputMode,
        command: .read(ReadInput(
          selector: sel,
          last: last,
          source: requestedSource,
          waitStable: waitStable,
          stableIntervalMs: stableInterval,
          stablePeriodMs: stablePeriod,
          waitTimeoutSeconds: waitTimeout
        ))
      )
      try CLIRunner.execute(envelope) { response in
        try Self.validate(response: response, requestedSource: requestedSource)
      }
    }
  }

  private static func validate(
    response: CommandResponse,
    requestedSource: ReadInputSource
  ) throws {
    guard requestedSource == .detection else { return }
    guard let data = response.data,
      let payload = try? data.decode(as: ReadCommandPayload.self),
      payload.source == .detection
    else {
      throw ExitError(
        code: CLIErrorCode.readFailed,
        message: "The running Prowl app did not honor --source detection. Update or restart Prowl, then retry."
      )
    }
  }

  /// Stability tuning options only apply together with `--wait-stable`; validate ranges up front.
  private func validateStabilityOptions() throws {
    if !waitStable, stableInterval != nil || stablePeriod != nil || waitTimeout != nil {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "--stable-interval/--stable-period/--wait-timeout require --wait-stable."
      )
    }

    if let stableInterval, stableInterval < 50 || stableInterval > 5000 {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "--stable-interval must be between 50 and 5000 milliseconds."
      )
    }

    if let stablePeriod, stablePeriod < 100 || stablePeriod > 60000 {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "--stable-period must be between 100 and 60000 milliseconds."
      )
    }

    if let waitTimeout, waitTimeout < 1 || waitTimeout > 300 {
      throw ExitError(
        code: CLIErrorCode.invalidArgument,
        message: "--wait-timeout must be between 1 and 300 seconds."
      )
    }
  }
}
