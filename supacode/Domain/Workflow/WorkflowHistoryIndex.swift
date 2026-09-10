import Foundation
import ProwlCLIShared

/// Small navigation data, separate from step outputs and state payloads.
nonisolated struct WorkflowHistoryIndex: Codable, Equatable, Sendable, Identifiable {
  static let fileName = "navigation.json"
  let id: UUID
  let name: String
  let worktreeID: String
  let root: String
  let state: String
  let startedAt: Date
  let finishedAt: Date?
  let sourcePaneID: UUID?
  let participants: [String: [UUID]]
  let sessions: [String: [String]]

  func matches(paneID: UUID?, session: String?) -> Bool {
    if let paneID, sourcePaneID == paneID || participants.values.contains(where: { $0.contains(paneID) }) {
      return true
    }
    return session.map { session in sessions.values.contains { $0.contains(session) } } ?? false
  }

  func relationship(paneID: UUID?, session: String?) -> String? {
    if let paneID, sourcePaneID == paneID { return "Started here" }
    let roles = Set(participants.keys).union(sessions.keys).filter { role in
      (paneID.map { participants[role]?.contains($0) == true } ?? false)
        || (session.map { sessions[role]?.contains($0) == true } ?? false)
    }.sorted()
    return roles.isEmpty ? nil : "Role: " + roles.joined(separator: ", ")
  }

  init(record: WorkflowRunRecord) {
    id = record.run.id
    name = record.run.workflowName
    worktreeID = record.worktree.id
    root = record.worktree.path
    state = record.run.status.state
    startedAt = record.run.startedAt
    finishedAt = record.run.finishedAt
    sourcePaneID = record.sourcePaneID
    var panes = record.participants ?? [:]
    for (role, binding) in record.bindings {
      if let pane = binding.pane, !panes[role, default: []].contains(pane) { panes[role, default: []].append(pane) }
    }
    participants = panes.mapValues { Array(Set($0.map(\.surfaceID))) }
    var identities = panes.mapValues { Array(Set($0.compactMap(\.sessionIdentity))) }
    if let source = record.sourceSessionIdentity { identities["initiator", default: []].append(source) }
    sessions = identities
  }

  init(
    id: UUID, name: String, worktreeID: String, root: String, state: String, startedAt: Date,
    finishedAt: Date?, sourcePaneID: UUID?, participants: [String: [UUID]], sessions: [String: [String]]
  ) {
    self.id = id
    self.name = name
    self.worktreeID = worktreeID
    self.root = root
    self.state = state
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.sourcePaneID = sourcePaneID
    self.participants = participants
    self.sessions = sessions
  }
}

nonisolated struct WorkflowHistoryStepDefinition: Codable, Equatable, Sendable {
  let id: String
  let title: String
  let loop: String?
  var kind: String = ""
  var actionID: String?

  static func flatten(_ steps: [WorkflowStepDefinition], loop: String? = nil) -> [Self] {
    steps.flatMap { step in
      // Dynamic titles are captured at execution, not evaluated later against changed state.
      let title = step.title.flatMap { $0.contains("{{") ? nil : $0 } ?? step.historyTitle
      var current = Self(id: step.id, title: title, loop: loop, kind: step.action.verb)
      if case .action(let id, _) = step.action { current.actionID = id }
      let nestedLoop: String?
      if case .control(.loop) = step.action { nestedLoop = step.id } else { nestedLoop = loop }
      return [current] + flatten(step.action.children, loop: nestedLoop)
    }
  }
}

nonisolated extension WorkflowStepDefinition {
  var historyTitle: String {
    switch action {
    case .message(let role, _, _): "Message \(role)"
    case .launch(let role, _, _, _): "Launch \(role)"
    case .action(let id, _): "Run \(id)"
    case .notify: "Send to Prowl Notifications"
    case .close(let role): "Close \(role)"
    case .control(let control):
      switch control {
      case .conditional: "Choose a branch"
      case .loop: "Loop \(id)"
      case .set: "Update workflow state"
      case .breakLoop: "Exit loop"
      case .continueLoop: "Continue loop"
      }
    }
  }
}
