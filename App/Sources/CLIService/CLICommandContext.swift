// supacode/CLIService/CLICommandContext.swift
// Per-connection context threaded from the socket server to handlers.

import Foundation

nonisolated struct CallerProcessIdentity: Sendable, Equatable {
  let processID: pid_t
  let startedAt: Date?
}

/// A caller whose ancestry reaches Codex's shared app-server daemon (Codex 0.157+). The
/// daemon runs every thread's commands with the environment and parent of whichever process
/// last started it, so only the per-thread `CODEX_THREAD_ID` can identify the caller's pane.
nonisolated struct CodexDaemonCaller: Sendable, Equatable {
  let daemon: CallerProcessIdentity
  /// Read from the caller's own environment by the server, never claimed by the client.
  let threadID: String?
  /// The pane whose Codex TUI drives that thread; see `CodexDaemonThreadMapper`.
  var pane: CodexThreadPane?
}

nonisolated struct CodexThreadPane: Sendable, Equatable {
  let surfaceID: UUID
  /// When the pane's current TUI started its session log. It ties the mapping to one TUI
  /// process, because each launch truncates the log.
  let sessionStartedAt: Date
}

/// Connection-scoped facts about the calling `prowl` process. The ancestry is
/// frozen at accept time because a short-lived hook may exit before MainActor
/// routing begins.
nonisolated struct CLICommandContext: Sendable, Equatable {
  let callerProcessID: pid_t?
  let callerProcessAncestry: [CallerProcessIdentity]
  var codexDaemonCaller: CodexDaemonCaller?

  init(callerProcessID: pid_t? = nil) {
    self.callerProcessID = callerProcessID
    callerProcessAncestry = []
    codexDaemonCaller = nil
  }

  init(
    callerProcessID: pid_t?,
    callerProcessAncestry: [CallerProcessIdentity],
    codexDaemonCaller: CodexDaemonCaller? = nil
  ) {
    self.callerProcessID = callerProcessID
    self.callerProcessAncestry = callerProcessAncestry
    self.codexDaemonCaller = codexDaemonCaller
  }
}

/// A pane owned by the process ancestry of a CLI caller.
nonisolated struct CallerPane: Sendable, Equatable {
  let worktreeID: Worktree.ID
  let surfaceID: UUID
  let processAncestry: [AgentProcessGeneration]
  /// Set only for a Codex daemon caller mapped through the pane's TUI session log.
  let codexSessionStartedAt: Date?

  init(
    worktreeID: Worktree.ID,
    surfaceID: UUID,
    processAncestry: [AgentProcessGeneration] = [],
    codexSessionStartedAt: Date? = nil
  ) {
    self.worktreeID = worktreeID
    self.surfaceID = surfaceID
    self.processAncestry = processAncestry
    self.codexSessionStartedAt = codexSessionStartedAt
  }

  /// Whether the caller runs inside `generation`: in its process tree, or, for a Codex daemon
  /// caller, in a thread driven by the TUI that started the pane's session log.
  func belongs(to generation: AgentProcessGeneration) -> Bool {
    if processAncestry.contains(generation) { return true }
    guard let codexSessionStartedAt else { return false }
    return CodexTUISessionLog.belongs(sessionStartedAt: codexSessionStartedAt, toProcessStartedAt: generation.startedAt)
  }
}

/// The caller's ancestry up to, not including, a Codex managed daemon.
nonisolated struct CallerProcessWalk: Sendable, Equatable {
  let ancestry: [CallerProcessIdentity]
  let codexDaemon: CallerProcessIdentity?
}

/// Resolves the calling `prowl` process to the pane whose shell spawned it by
/// walking the caller's process ancestry against the live shell-PID map. A
/// caller outside any Prowl pane (another terminal app, a script, tmux's
/// server-owned processes) resolves to nil — never to a guess.
nonisolated enum CallerPaneResolver {
  /// Walks up from the caller and stops before a Codex managed daemon. The daemon keeps the
  /// process that started it as its parent, so walking past it would reach that pane's shell
  /// for a command from any other pane.
  static func processWalk(
    forCallerProcess callerPID: pid_t,
    parentProcessID: (pid_t) -> pid_t? = { pid in
      ProcessDetection.processBSDInfo(pid: pid).map { pid_t($0.pbi_ppid) }
    },
    processStartDate: (pid_t) -> Date? = ProcessDetection.processStartDate,
    isCodexDaemon: (pid_t) -> Bool = ProcessDetection.isCodexManagedDaemon
  ) -> CallerProcessWalk {
    var pid = callerPID
    var hops = 0
    var ancestry: [CallerProcessIdentity] = []
    while pid > 1, hops < 32 {
      let identity = CallerProcessIdentity(processID: pid, startedAt: processStartDate(pid))
      if isCodexDaemon(pid) {
        return CallerProcessWalk(ancestry: ancestry, codexDaemon: identity)
      }
      ancestry.append(identity)
      guard let parent = parentProcessID(pid), parent != pid else { break }
      pid = parent
      hops += 1
    }
    return CallerProcessWalk(ancestry: ancestry, codexDaemon: nil)
  }

  static func processAncestry(
    forCallerProcess callerPID: pid_t,
    parentProcessID: (pid_t) -> pid_t? = { pid in
      ProcessDetection.processBSDInfo(pid: pid).map { pid_t($0.pbi_ppid) }
    },
    processStartDate: (pid_t) -> Date? = ProcessDetection.processStartDate,
    isCodexDaemon: (pid_t) -> Bool = ProcessDetection.isCodexManagedDaemon
  ) -> [CallerProcessIdentity] {
    processWalk(
      forCallerProcess: callerPID,
      parentProcessID: parentProcessID,
      processStartDate: processStartDate,
      isCodexDaemon: isCodexDaemon
    ).ancestry
  }

  static func pane(
    forCallerProcess callerPID: pid_t,
    paneByShellPID: [pid_t: CallerPane],
    parentProcessID: (pid_t) -> pid_t? = { pid in
      ProcessDetection.processBSDInfo(pid: pid).map { pid_t($0.pbi_ppid) }
    },
    processStartDate: (pid_t) -> Date? = ProcessDetection.processStartDate,
    isCodexDaemon: (pid_t) -> Bool = ProcessDetection.isCodexManagedDaemon
  ) -> CallerPane? {
    pane(
      forCallerProcessAncestry: processAncestry(
        forCallerProcess: callerPID,
        parentProcessID: parentProcessID,
        processStartDate: processStartDate,
        isCodexDaemon: isCodexDaemon
      ),
      paneByShellPID: paneByShellPID
    )
  }

  /// The one resolution every caller-scoped command uses. A Codex daemon caller resolves
  /// only through its mapped thread pane; it never falls back to ancestry or to the pane
  /// named by its inherited `PROWL_PANE_ID`.
  static func pane(for context: CLICommandContext, paneByShellPID: [pid_t: CallerPane]) -> CallerPane? {
    if let codex = context.codexDaemonCaller {
      guard let mapped = codex.pane,
        let pane = paneByShellPID.values.first(where: { $0.surfaceID == mapped.surfaceID })
      else { return nil }
      return CallerPane(
        worktreeID: pane.worktreeID,
        surfaceID: pane.surfaceID,
        processAncestry: context.callerProcessAncestry.compactMap { identity in
          identity.startedAt.map { AgentProcessGeneration(pid: identity.processID, startedAt: $0) }
        },
        codexSessionStartedAt: mapped.sessionStartedAt
      )
    }
    if !context.callerProcessAncestry.isEmpty {
      return pane(forCallerProcessAncestry: context.callerProcessAncestry, paneByShellPID: paneByShellPID)
    }
    guard let callerProcessID = context.callerProcessID else { return nil }
    return pane(forCallerProcess: callerProcessID, paneByShellPID: paneByShellPID)
  }

  static func pane(
    forCallerProcessAncestry identities: [CallerProcessIdentity],
    paneByShellPID: [pid_t: CallerPane]
  ) -> CallerPane? {
    var generations: [AgentProcessGeneration] = []
    for identity in identities {
      if let startedAt = identity.startedAt {
        generations.append(
          AgentProcessGeneration(pid: identity.processID, startedAt: startedAt)
        )
      }
      if let pane = paneByShellPID[identity.processID] {
        return CallerPane(
          worktreeID: pane.worktreeID,
          surfaceID: pane.surfaceID,
          processAncestry: generations
        )
      }
    }
    return nil
  }
}
