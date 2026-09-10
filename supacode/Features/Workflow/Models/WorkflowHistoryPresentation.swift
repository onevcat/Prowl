import Foundation
import ProwlCLIShared

nonisolated enum WorkflowHistoryScope: String, CaseIterable, Equatable, Sendable {
  case pane = "This Pane"
  case worktree = "This Worktree"
  case all = "All Runs"
}

nonisolated struct WorkflowHistoryContext: Equatable, Sendable {
  var paneID: UUID?
  var session: String?
  var worktreeID: String?
  var livePaneIDs: Set<UUID> = []
}

nonisolated enum WorkflowHistorySessionIdentity {
  static func resolve(agent: DetectedAgent, detected: AgentSession?, currentSignal: AgentSignal?) -> String? {
    if let signal = currentSignal, signal.confidence == .exact,
      case .hook(let runtime, _) = signal.source, runtime.agent == agent
    {
      if case .sessionEnd = signal.kind { return nil }
      if let sessionID = signal.sessionID, !sessionID.isEmpty { return "\(agent.rawValue):\(sessionID)" }
    }
    guard let detected, detected.confidence == .exact, !detected.id.isEmpty else { return nil }
    return "\(agent.rawValue):\(detected.id)"
  }
}

nonisolated enum WorkflowHistoryStatus {
  static func label(_ state: String) -> String {
    switch state {
    case "completed": "Completed"
    case "active", "running": "Running"
    case "needs_attention": "Needs Attention"
    case "failed": "Failed"
    case "skipped": "Skipped"
    case "branch_not_selected": "Branch not selected"
    case "pending": "Not started"
    case "not_run": "Not run"
    case "cancelled": "Cancelled"
    case "interrupted": "Interrupted"
    case "iteration_limit_reached": "Iteration limit reached"
    default: "Unavailable"
    }
  }

  static func symbol(_ state: String) -> String {
    switch state {
    case "completed": "checkmark.circle.fill"
    case "active", "running": "play.circle"
    case "needs_attention", "failed", "iteration_limit_reached": "exclamationmark.circle.fill"
    case "skipped": "forward.end.circle"
    case "branch_not_selected": "arrow.triangle.branch"
    case "cancelled": "stop.circle"
    case "interrupted": "pause.circle"
    case "not_run": "minus.circle"
    default: "circle"
    }
  }
}

nonisolated struct WorkflowHistoryStepGroup: Identifiable, Sendable {
  let id: String
  let title: String
  let state: String
  let iteration: Int?
  let attempts: [WorkflowRunRecord.Step]
  let definition: WorkflowHistoryStepDefinition
  let invocations: [Int: WorkflowRunRecordInvocation]
  var iterationLabel: String?

  var subtitle: String {
    [WorkflowHistoryStatus.label(state), contextLabel].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  var attemptLabel: String { definition.kind == "while" ? "Check" : "Attempt" }

  var contextLabel: String {
    var parts: [String] = []
    if let iterationLabel { parts.append(iterationLabel) } else if let iteration { parts.append("Round \(iteration)") }
    if attempts.count > 1 { parts.append("\(attempts.count) \(attemptLabel.lowercased())s") }
    return parts.joined(separator: " · ")
  }

  static func groups(_ record: WorkflowRunRecord) -> [Self] {
    let definitions = record.stepDefinitions
    let positions = Dictionary(
      definitions.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    let invocations = Dictionary(
      record.invocations.map { ($0.ordinal, $0) }, uniquingKeysWith: { first, _ in first })
    let titles = Dictionary(definitions.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    let byStep = Dictionary(grouping: record.steps, by: \.id)
    var result: [(group: Self, order: [Int])] = []
    for definition in definitions {
      let records = byStep[definition.id] ?? []
      let byPath = Dictionary(grouping: records) { $0.iterationPath ?? [] }
      let paths = byPath.isEmpty ? [[]] : Array(byPath.keys)
      for path in paths {
        let attempts = byPath[path] ?? []
        let latest = attempts.last
        var state = latest?.state.rawValue ?? (record.run.status.isTerminal ? "not_run" : "pending")
        if latest?.state == .active && record.run.status.isTerminal { state = "interrupted" }
        if record.run.status.attention?.step == definition.id && latest?.state == .active { state = "needs_attention" }
        if latest?.state == .skipped && latest?.branchExcluded == true { state = "branch_not_selected" }
        let group = Self(
          id: "\(definition.id):\(path.joined(separator: "/"))",
          title: latest?.title ?? definition.title, state: state, iteration: latest?.iteration, attempts: attempts,
          definition: definition, invocations: invocations,
          iterationLabel: path.isEmpty
            ? nil
            : path.map { component in
              let parts = component.split(separator: ":")
              let loop = parts.first.map(String.init) ?? ""
              return "\(titles[loop] ?? loop) · Round \(parts.last ?? "?")"
            }.joined(separator: " / "))
        var order: [Int] = []
        for component in path {
          let parts = component.split(separator: ":")
          let loop = parts.first.map(String.init) ?? ""
          order += [positions[loop] ?? positions[definition.loop ?? ""] ?? 0, Int(parts.last ?? "0") ?? 0]
        }
        order.append(positions[definition.id] ?? 0)
        result.append((group, order))
      }
    }
    return result.sorted { $0.order.lexicographicallyPrecedes($1.order) }.map(\.group)
  }
}

nonisolated enum WorkflowHistoryOutputIntent: Equatable, Sendable {
  case openFile(URL)
  case copyFile(URL)
  case copyText(String)
  case openArtifact(URL, worktree: URL)
  case revealArtifact(URL, worktree: URL)
  case reveal(URL)
  case openText(String, String)
  case openJSON([String: WorkflowJSONValue])
  case copyJSON([String: WorkflowJSONValue])
  case keep(URL)
  case export(URL)
}
