import Foundation

/// The outgoing side of a handoff as observed on the source pane: the
/// session context persisted into the artifact, the argv-derived launch
/// observation, and the pid-anchored native session used for a fork briefing.
nonisolated struct HandoffSourceContext: Sendable, Equatable {
  let sessionContext: HandoffStore.SessionContext?
  let observation: AgentLaunchObservation?
  let session: AgentSession?
}

/// Where a transition's briefing comes from. The entry point decides; the
/// coordinator executes. Inline is the primary path (the author is present),
/// fork is the explicit fallback (the author is not), none is context-only.
nonisolated enum HandoffBriefingSource: Sendable, Equatable {
  /// Agent-authored text supplied with the command (`--brief`). Invalid text
  /// throws before any filesystem side effect.
  case inline(String)
  /// Resume the source session headlessly and use its validated reply.
  /// Failure degrades the transition to context-only (`HandoffBriefing.failed`).
  case fork(AgentResumeRequest)
  /// Intentionally context-only (`--no-brief`, or no resumable source).
  case none
}

nonisolated enum HandoffBriefingError: Error, Equatable, Sendable {
  /// Inline briefing text failed validation; nothing was written.
  case invalidInlineBrief
}

/// A briefing collected before the handoff's irreversible artifact work
/// begins. HUD fallbacks use this to establish a visible commit boundary.
nonisolated struct HandoffPreparedBriefing: Equatable, Sendable {
  let artifact: String?
  let outcome: HandoffBriefing

  static let contextOnly = Self(artifact: nil, outcome: .none)
}

/// The one pure transition core every handoff entry point drives — the CLI
/// handler for agent-initiated handoffs and the HUD's fork/context-only
/// fallbacks. A transition always runs the same sequence:
///
///   collect briefing → archive outgoing state → install fresh briefing
///   (or remove the stale one) → refresh generated context → [launch] → log
///
/// Launching the receiving agent stays with the caller — the CLI needs the
/// synchronously resolved pane for its payload while UI callers fire a
/// terminal command — but every persisted artifact and log format lives here.
nonisolated struct HandoffCoordinator: Sendable {
  /// Resumes a source session headlessly and returns its reply text.
  typealias Resume = @Sendable (AgentResumeRequest, URL) async throws -> String

  let store: HandoffStore
  private let resume: Resume

  init(store: HandoffStore, resume: @escaping Resume) {
    self.store = store
    self.resume = resume
  }

  /// Everything `handoff to` persists before the receiving agent launches.
  struct TransitionArtifacts: Sendable {
    let briefing: HandoffBriefing
    let save: HandoffStore.SaveResult
    let archivedPath: String?
    /// A fresh `current.md` exists for the receiver to read.
    var hasBriefing: Bool { briefing.wroteBriefing }
  }

  /// How the receiving agent was (or wasn't) started, for the log line.
  enum LaunchDisposition: Sendable {
    /// Launched into a resolved pane (CLI path).
    case pane(String)
    /// Launch was handed to the terminal without a resolved pane (UI path).
    case requested
    /// `--no-launch`.
    case skipped
    /// The launch attempt returned no pane.
    case failed
  }

  /// Resolve the briefing source to validated artifact text. Inline text that
  /// fails validation throws (the caller reports it; nothing was written).
  /// A cancelled fork rethrows `CancellationError` so an aborted UI run never
  /// degrades into a context-only transition behind the user's back.
  /// Resolve a briefing source to validated artifact text. Inline text that
  /// fails validation throws (the caller reports it; nothing was written).
  /// A cancelled fork rethrows `CancellationError` so an aborted UI run never
  /// degrades into a context-only transition behind the user's back.
  func collectBriefing(_ source: HandoffBriefingSource) async throws -> HandoffPreparedBriefing {
    switch source {
    case .inline(let raw):
      guard let artifact = HandoffStore.validatedBriefing(from: raw) else {
        throw HandoffBriefingError.invalidInlineBrief
      }
      return HandoffPreparedBriefing(artifact: artifact, outcome: .inline)
    case .fork(let request):
      do {
        let reply = try await resume(request, store.rootURL)
        try Task.checkCancellation()
        guard let artifact = HandoffStore.validatedBriefing(from: reply) else {
          return HandoffPreparedBriefing(artifact: nil, outcome: .failed)
        }
        return HandoffPreparedBriefing(artifact: artifact, outcome: .fork)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        return HandoffPreparedBriefing(artifact: nil, outcome: .failed)
      }
    case .none:
      return .contextOnly
    }
  }

  /// `handoff to`, up to the destination launch: collect the briefing, archive
  /// the outgoing state, install the fresh briefing (or remove the stale one),
  /// and refresh generated context. The archive precedes every rewrite, so the
  /// outgoing round always survives in `archive/` regardless of what the new
  /// briefing contains.
  func makeTransitionArtifacts(
    outgoingAgent: String?,
    toAgent: String,
    sessionContext: HandoffStore.SessionContext?,
    briefingSource: HandoffBriefingSource,
    now: Date
  ) async throws -> TransitionArtifacts {
    try await makeTransitionArtifacts(
      outgoingAgent: outgoingAgent,
      toAgent: toAgent,
      sessionContext: sessionContext,
      briefing: try await collectBriefing(briefingSource),
      now: now
    )
  }

  /// Performs an already-authorized artifact transition. HUD fallbacks call
  /// this only after their reducer enters the non-cancellable finishing stage.
  func makeTransitionArtifacts(
    outgoingAgent: String?,
    toAgent: String,
    sessionContext: HandoffStore.SessionContext?,
    briefing: HandoffPreparedBriefing,
    now: Date
  ) async throws -> TransitionArtifacts {
    let store = self.store
    let from = outgoingAgent ?? "agent"
    return try await Task.detached {
      let archivedPath = try store.archiveCurrent(from: from, toAgent: toAgent, now: now)
      if let artifact = briefing.artifact {
        try store.writeBriefing(artifact, archivingPrevious: false, now: now)
      } else {
        try store.removeCurrentArtifact()
      }
      let save = try store.save(
        outgoingAgent: outgoingAgent,
        sessionContext: sessionContext,
        note: nil,
        briefing: nil,
        now: now
      )
      return TransitionArtifacts(briefing: briefing.outcome, save: save, archivedPath: archivedPath)
    }.value
  }

  /// `handoff save`: a deferred-handoff checkpoint. Installs a fresh briefing
  /// when one is available (archiving the replaced one) and refreshes
  /// generated context. Unlike a transition it never removes an earlier
  /// checkpoint — with no receiver, the last validated briefing stays valid.
  func makeCheckpoint(
    outgoingAgent: String?,
    sessionContext: HandoffStore.SessionContext?,
    note: String?,
    briefingSource: HandoffBriefingSource,
    now: Date
  ) async throws -> (save: HandoffStore.SaveResult, briefing: HandoffBriefing) {
    try await makeCheckpoint(
      outgoingAgent: outgoingAgent,
      sessionContext: sessionContext,
      note: note,
      briefing: try await collectBriefing(briefingSource),
      now: now
    )
  }

  /// Persists a briefing collected before the HUD's commit boundary.
  func makeCheckpoint(
    outgoingAgent: String?,
    sessionContext: HandoffStore.SessionContext?,
    note: String?,
    briefing: HandoffPreparedBriefing,
    now: Date
  ) async throws -> (save: HandoffStore.SaveResult, briefing: HandoffBriefing) {
    let store = self.store
    let save = try await Task.detached {
      if let artifact = briefing.artifact {
        try store.writeBriefing(artifact, archivingPrevious: true, now: now)
      }
      return try store.save(
        outgoingAgent: outgoingAgent,
        sessionContext: sessionContext,
        note: note,
        briefing: briefing.outcome,
        now: now
      )
    }.value
    return (save, briefing.outcome)
  }

  /// Append the single transition line; every entry point shares this format.
  func logTransition(
    from: String,
    toAgent: String,
    disposition: LaunchDisposition,
    briefing: HandoffBriefing,
    toProfileID: AgentProfile.ID? = nil,
    toProfileName: String? = nil,
    archivedPath: String? = nil,
    note: String? = nil,
    source: String? = nil,
    now: Date
  ) async {
    let line = Self.transitionLogLine(
      from: from,
      toAgent: toAgent,
      disposition: disposition,
      briefing: briefing,
      toProfileID: toProfileID,
      toProfileName: toProfileName,
      archivedPath: archivedPath,
      note: note,
      source: source
    )
    let store = self.store
    try? await Task.detached {
      try store.appendLog(line, now: now)
    }.value
  }

  static func transitionLogLine(
    from: String,
    toAgent: String,
    disposition: LaunchDisposition,
    briefing: HandoffBriefing,
    toProfileID: AgentProfile.ID? = nil,
    toProfileName: String? = nil,
    archivedPath: String? = nil,
    note: String? = nil,
    source: String? = nil
  ) -> String {
    let launchPart =
      switch disposition {
      case .pane(let paneID): "  pane=\(paneID)"
      case .requested: "  launch=requested"
      case .skipped: "  (no launch)"
      case .failed: "  launch=failed"
      }
    var line = "\(from) → \(toAgent)\(launchPart)  briefing=\(briefing.rawValue)"
    if let toProfileID {
      line += "  profile_id=\(toProfileID.uuidString)"
    }
    if let toProfileName {
      let name =
        toProfileName
        .replacing("\r", with: " ")
        .replacing("\n", with: " ")
        .replacing("\"", with: "'")
      line += "  profile=\"\(name)\""
    }
    if case .failed = disposition, let archivedPath {
      line += "  archive=\(archivedPath)"
    }
    if let source {
      line += "  source=\(source)"
    }
    if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      line += "  note=\"\(note.replacing("\n", with: " "))\""
    }
    return line
  }
}
