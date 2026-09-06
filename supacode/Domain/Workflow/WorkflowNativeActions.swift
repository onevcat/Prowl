// supacode/Domain/Workflow/WorkflowNativeActions.swift
// Execution of the V1 native actions (dsl-spec §4, decision H12): `handoff.transition` and
// `handoff.checkpoint` over the `.prowl/handoff/` coordinator, `git.context` over the same
// context generator. Typed inputs and outputs follow `WorkflowActionRegistry`.

import Darwin
import Foundation
import ProwlCLIShared

nonisolated struct WorkflowActionContext: Sendable {
  let runID: UUID
  /// The source worktree root; every path input must stay inside it.
  let rootURL: URL
  /// Role → detected / frozen agent token (nil for a bare shell).
  let roleAgents: [String: String?]
  /// The agent token of the `current` role: the outgoing side of a checkpoint or context.
  let outgoingAgent: String?
  let sessionContext: HandoffStore.SessionContext?
  let now: Date

  init(
    runID: UUID,
    rootURL: URL,
    roleAgents: [String: String?],
    outgoingAgent: String?,
    sessionContext: HandoffStore.SessionContext? = nil,
    now: Date
  ) {
    self.runID = runID
    self.rootURL = rootURL.standardizedFileURL
    self.roleAgents = roleAgents
    self.outgoingAgent = outgoingAgent
    self.sessionContext = sessionContext
    self.now = now
  }
}

nonisolated enum WorkflowActionError: Error, Equatable, Sendable {
  case unknownAction(String)
  case missingInput(String)
  case unknownRole(String)
  case unreadableBriefing(path: String)
  /// The briefing lacks the required sections; nothing was written.
  case invalidBriefing(path: String)
  /// A path input resolves outside the worktree root.
  case unsafePath(String)
  case failed(String)

  var message: String {
    switch self {
    case .unknownAction(let id): "Unknown action '\(id)'."
    case .missingInput(let name): "Input '\(name)' is required."
    case .unknownRole(let role): "Role '\(role)' is not bound in this run."
    case .unreadableBriefing(let path): "The briefing at \(path) cannot be read."
    case .invalidBriefing(let path): HandoffCommandHandler.invalidBriefMessage() + " (\(path))"
    case .unsafePath(let path): "The path \(path) lies outside the worktree."
    case .failed(let detail): detail
    }
  }
}

/// The boundary the run machine's `.runAction` effect is executed through; B3 passes the
/// native runner, tests pass fakes.
protocol WorkflowActionExecuting: Sendable {
  func execute(actionID: String, inputs: [String: String], context: WorkflowActionContext) async throws -> [String:
    String]
}

nonisolated struct WorkflowNativeActionRunner: WorkflowActionExecuting {
  func execute(actionID: String, inputs: [String: String], context: WorkflowActionContext) async throws -> [String:
    String]
  {
    switch actionID {
    case "handoff.transition":
      return try await transition(inputs: inputs, context: context)
    case "handoff.checkpoint":
      return try await checkpoint(inputs: inputs, context: context)
    case "git.context":
      return try await gitContext(inputs: inputs, context: context)
    default:
      throw WorkflowActionError.unknownAction(actionID)
    }
  }

  // MARK: handoff.transition

  /// Archive-first transition; without `briefing` it is the context-only transition: the
  /// outgoing `current.md` is archived and removed so a stale briefing never impersonates a
  /// fresh one, `context.md` is regenerated, and the context-only kickoff prompt is returned.
  private func transition(inputs: [String: String], context: WorkflowActionContext) async throws -> [String: String] {
    guard let fromRole = inputs["from"] else { throw WorkflowActionError.missingInput("from") }
    guard let toRole = inputs["to"] else { throw WorkflowActionError.missingInput("to") }
    guard let fromAgent = context.roleAgents[fromRole] else { throw WorkflowActionError.unknownRole(fromRole) }
    guard let toAgent = context.roleAgents[toRole] else { throw WorkflowActionError.unknownRole(toRole) }
    let store = HandoffStore(rootURL: context.rootURL)
    let coordinator = HandoffCoordinator(store: store)
    let briefing = try prepareBriefing(path: inputs["briefing"], coordinator: coordinator, context: context)
    let artifacts: HandoffCoordinator.TransitionArtifacts
    do {
      artifacts = try await coordinator.makeTransitionArtifacts(
        outgoingAgent: fromAgent,
        toAgent: toAgent ?? "agent",
        sessionContext: context.sessionContext,
        briefing: briefing,
        now: context.now)
    } catch {
      throw WorkflowActionError.failed("Failed to prepare the handoff: \(error)")
    }
    await coordinator.logTransition(
      from: fromAgent ?? "agent",
      toAgent: toAgent ?? "agent",
      disposition: .requested,
      briefing: artifacts.briefing,
      archivedPath: artifacts.archivedPath,
      note: inputs["note"],
      source: "workflow \(context.runID.uuidString)",
      now: context.now)
    return [
      "kickoff_prompt": HandoffCommandHandler.kickoffPrompt(hasBriefing: artifacts.hasBriefing),
      "artifact_path": artifacts.save.artifactPath,
      "has_briefing": artifacts.hasBriefing ? "true" : "false",
    ]
  }

  // MARK: handoff.checkpoint

  /// Installs a fresh briefing when one is given (archiving the replaced one) and refreshes
  /// `context.md`; without `briefing` an earlier valid `current.md` stays in place.
  private func checkpoint(inputs: [String: String], context: WorkflowActionContext) async throws -> [String: String] {
    let store = HandoffStore(rootURL: context.rootURL)
    let coordinator = HandoffCoordinator(store: store)
    let briefing = try prepareBriefing(path: inputs["briefing"], coordinator: coordinator, context: context)
    do {
      let (save, outcome) = try await coordinator.makeCheckpoint(
        outgoingAgent: context.outgoingAgent,
        sessionContext: context.sessionContext,
        note: inputs["note"] ?? "workflow \(context.runID.uuidString)",
        briefing: briefing,
        now: context.now)
      return [
        "artifact_path": save.artifactPath,
        "has_briefing": outcome.wroteBriefing ? "true" : "false",
      ]
    } catch {
      throw WorkflowActionError.failed("Failed to save the checkpoint: \(error)")
    }
  }

  // MARK: git.context

  /// The handoff context generator: writes `<root>/.prowl/handoff/context.md` and appends one
  /// line to the handoff log; `root` defaults to the worktree and must stay inside it.
  private func gitContext(inputs: [String: String], context: WorkflowActionContext) async throws -> [String: String] {
    let root = try containedPath(inputs["root"], context: context) ?? context.rootURL.resolvingSymlinksInPath()
    // The handoff store works on paths; re-walk the root without following links right before
    // it starts so a link planted after the containment check is refused (the residual window
    // inside the store's own writes stays on the pre-existing handoff trust model).
    let rootDescriptor = try Self.openContainedDirectory(root, root: context.rootURL.resolvingSymlinksInPath())
    _ = Darwin.close(rootDescriptor)
    let store = HandoffStore(rootURL: root)
    do {
      let save = try await Task.detached {
        try store.save(
          outgoingAgent: context.outgoingAgent,
          sessionContext: nil,
          note: "workflow \(context.runID.uuidString) git.context",
          now: context.now)
      }.value
      return [
        "path": store.contextURL.path(percentEncoded: false),
        "branch": save.repos.first?.branch ?? "",
      ]
    } catch {
      throw WorkflowActionError.failed("Failed to generate the context: \(error)")
    }
  }

  // MARK: Helpers

  private func prepareBriefing(
    path: String?, coordinator: HandoffCoordinator, context: WorkflowActionContext
  ) throws -> HandoffPreparedBriefing {
    guard let path else { return .contextOnly }
    guard let url = try containedPath(path, context: context) else { return .contextOnly }
    let text = try Self.readRegularFile(url, root: context.rootURL.resolvingSymlinksInPath(), reportedPath: path)
    do {
      return try coordinator.collectBriefing(.inline(text))
    } catch {
      throw WorkflowActionError.invalidBriefing(path: path)
    }
  }

  /// A path input resolved against the worktree root and required to stay inside it. The
  /// canonical (symlink-resolved) URL is what the action operates on, so the containment
  /// that was checked is the containment that is used.
  private func containedPath(_ path: String?, context: WorkflowActionContext) throws -> URL? {
    guard let path, !path.isEmpty else { return nil }
    let url = URL(filePath: path, relativeTo: context.rootURL).standardizedFileURL
    let canonical = url.resolvingSymlinksInPath()
    let base = context.rootURL.resolvingSymlinksInPath()
    guard canonical == base || AgentProfileLaunchPlanner.isContained(canonical, in: base) else {
      throw WorkflowActionError.unsafePath(path)
    }
    return canonical
  }

  /// Opens `directory` (a canonical path inside `root`) by walking every component from the
  /// root with `O_NOFOLLOW | O_DIRECTORY`, so a component swapped for a link after the
  /// containment check is refused rather than followed. Returns an owned descriptor.
  private static func openContainedDirectory(_ directory: URL, root: URL) throws -> Int32 {
    let rootPath = AgentProfileLaunchPlanner.pathString(root)
    var descriptor = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw WorkflowActionError.unsafePath(rootPath) }
    let rootComponents = root.standardizedFileURL.pathComponents
    let components = directory.standardizedFileURL.pathComponents
    guard components.count >= rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents
    else {
      _ = Darwin.close(descriptor)
      throw WorkflowActionError.unsafePath(AgentProfileLaunchPlanner.pathString(directory))
    }
    for component in components.dropFirst(rootComponents.count) {
      let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      _ = Darwin.close(descriptor)
      guard next >= 0 else { throw WorkflowActionError.unsafePath(AgentProfileLaunchPlanner.pathString(directory)) }
      descriptor = next
    }
    return descriptor
  }

  /// Reads a briefing by walking its directory from the worktree root without following links
  /// and opening the leaf with `O_NOFOLLOW`; requires a regular file.
  private static func readRegularFile(_ url: URL, root: URL, reportedPath: String) throws -> String {
    let directoryDescriptor = try openContainedDirectory(url.deletingLastPathComponent(), root: root)
    let descriptor = openat(directoryDescriptor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW)
    _ = Darwin.close(directoryDescriptor)
    guard descriptor >= 0 else {
      if errno == ELOOP { throw WorkflowActionError.unsafePath(reportedPath) }
      throw WorkflowActionError.unreadableBriefing(path: reportedPath)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var statistics = stat()
    guard fstat(descriptor, &statistics) == 0, (statistics.st_mode & S_IFMT) == S_IFREG else {
      throw WorkflowActionError.unreadableBriefing(path: reportedPath)
    }
    guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
      throw WorkflowActionError.unreadableBriefing(path: reportedPath)
    }
    return text
  }
}
