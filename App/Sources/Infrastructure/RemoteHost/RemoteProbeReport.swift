import Foundation

/// One remote process as a probe snapshot reported it (docs-ai 082, C6).
nonisolated struct RemoteProbeProcess: Equatable, Sendable {
  let pid: Int32
  let parentPID: Int32
  let processGroupID: Int32
  /// The host's native start token: Linux start ticks, macOS `lstart`.
  let startToken: String
  let elapsedSeconds: Int
  let name: String
  /// The argument vector when the host reports it losslessly (Linux).
  let arguments: [String]?
  /// The space-joined command line (macOS reports only this form).
  let commandLine: String
  let workingDirectory: String?
}

/// An SSH session with a terminal on the host, and its foreground job.
nonisolated struct RemoteProbeSession: Equatable, Sendable {
  /// `LC_PROWL_PANE` of the session, when the probe could read it.
  let paneID: UUID?
  let anchorPID: Int32
  let tty: String?
  let foregroundProcessGroupID: Int32
  let processes: [RemoteProbeProcess]
  /// The tmux pane this session shows, when a tmux client is in its foreground.
  var tmux: RemoteProbeTmuxPane?
}

/// The active pane of a tmux client in a session's foreground (docs-ai 082, L0 item 6). The
/// client maps to its pane through the server it talks to, never through the inherited
/// environment, which names the server's first client.
nonisolated struct RemoteProbeTmuxPane: Equatable, Sendable {
  static let screenLimit = 64 * 1024

  let clientPID: Int32
  /// tmux's pane id, such as `%3`.
  let paneID: String
  let tty: String?
  /// The pane shows a mode (copy mode, a chooser) instead of its program.
  let isInMode: Bool
  let foregroundProcessGroupID: Int32
  let processes: [RemoteProbeProcess]
  /// The pane's visible screen, as `capture-pane` prints it.
  let screen: String?
  /// The screen passed `screenLimit` and was cut.
  let isScreenTruncated: Bool
}

/// The parsed body of one probe run.
nonisolated struct RemoteProbeReport: Equatable, Sendable {
  enum OperatingSystem: String, Equatable, Sendable {
    case linux = "Linux"
    case darwin = "Darwin"
  }

  let operatingSystem: OperatingSystem
  let bootID: String
  let sessions: [RemoteProbeSession]
}

extension RemoteProbeSession {
  /// The session's foreground job as the classifier reads it: remote references that
  /// carry the host's boot id and each process's native start token.
  nonisolated func foregroundJob(connection: ConnectionKey, bootID: String) -> ForegroundJob? {
    RemoteProbeProcess.job(
      processes, processGroupID: foregroundProcessGroupID, connection: connection, bootID: bootID)
  }
}

extension RemoteProbeTmuxPane {
  /// The pane's foreground job, as `RemoteProbeSession.foregroundJob` builds it.
  nonisolated func foregroundJob(connection: ConnectionKey, bootID: String) -> ForegroundJob? {
    RemoteProbeProcess.job(
      processes, processGroupID: foregroundProcessGroupID, connection: connection, bootID: bootID)
  }
}

extension RemoteProbeProcess {
  nonisolated static func job(
    _ processes: [RemoteProbeProcess], processGroupID: Int32, connection: ConnectionKey, bootID: String
  ) -> ForegroundJob? {
    let members = processes.filter { $0.processGroupID == processGroupID }
    guard !members.isEmpty else { return nil }
    return ForegroundJob(
      processGroupID: processGroupID,
      processes: members.map { process in
        let argv0 = process.arguments?.first ?? process.commandLine.split(separator: " ").first.map(String.init)
        return ForegroundProcess(
          ref: .remote(
            RemoteProcessRef(
              connection: connection, bootID: bootID, pid: process.pid, startToken: process.startToken)),
          parentPID: process.parentPID,
          name: process.name,
          argv0: argv0.flatMap(ProcessDetection.basename),
          cmdline: process.commandLine,
          arguments: process.arguments
        )
      }
    )
  }
}
