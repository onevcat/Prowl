import Foundation

/// The Agents screen as data (docs-ai 089): how many agents are blocked, working or done, and
/// the Host's projects in Mac sidebar order, each with its agent panes by urgency and its
/// terminals folded apart. A state filter keeps only the agents in that state.
nonisolated struct MirrorAgentsRoster: Equatable, Sendable {
  struct Project: Identifiable, Equatable, Sendable {
    let name: String
    let color: String?
    let group: String?
    let order: Int?
    var agents: [MirrorPaneDescriptor]
    var terminals: [MirrorPaneDescriptor]

    var id: String { name }
    var hasBlocked: Bool { agents.contains { MirrorPaneState($0) == .blocked } }
  }

  let projects: [Project]
  /// Agent panes per state, before any filter.
  let counts: [MirrorPaneState: Int]

  var projectNames: [String] { projects.map(\.name) }

  init(panes: [MirrorPaneDescriptor], state filter: MirrorPaneState? = nil) {
    var counts: [MirrorPaneState: Int] = [:]
    for pane in panes where pane.agent != nil { counts[MirrorPaneState(pane), default: 0] += 1 }
    self.counts = counts
    var byName: [String: Project] = [:]
    for pane in panes {
      let name = pane.projectName ?? String(localized: "Other")
      var project =
        byName[name]
        ?? Project(
          name: name, color: pane.repositoryColor, group: pane.groupName, order: pane.projectOrder,
          agents: [], terminals: [])
      if pane.agent == nil {
        project.terminals.append(pane)
      } else {
        project.agents.append(pane)
      }
      byName[name] = project
    }
    var projects = byName.values.map { project in
      var sorted = project
      sorted.agents.sort(by: Self.urgency)
      sorted.terminals.sort { Self.title($0) < Self.title($1) }
      return sorted
    }
    projects.sort { lhs, rhs in
      switch (lhs.order, rhs.order) {
      case (let left?, let right?) where left != right: left < right
      case (.some, nil): true
      case (nil, .some): false
      default: lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
    }
    if let filter {
      projects = projects.compactMap { project in
        var kept = project
        kept.agents = project.agents.filter { MirrorPaneState($0) == filter }
        kept.terminals = []
        return kept.agents.isEmpty ? nil : kept
      }
    }
    self.projects = projects
  }

  /// Blocked before working before done before idle; the most recent change first.
  static func urgency(_ lhs: MirrorPaneDescriptor, _ rhs: MirrorPaneDescriptor) -> Bool {
    let left = MirrorPaneState(lhs).priority
    let right = MirrorPaneState(rhs).priority
    if left != right { return left < right }
    let leftDate = lhs.stateChangedDate ?? .distantPast
    let rightDate = rhs.stateChangedDate ?? .distantPast
    if leftDate != rightDate { return leftDate > rightDate }
    return title(lhs) < title(rhs)
  }

  static func title(_ pane: MirrorPaneDescriptor) -> String { pane.displayTitle }
}

extension MirrorPaneDescriptor {
  /// The name a person knows the pane by: the Mac tab title, else the roster subtitle.
  nonisolated var displayTitle: String {
    if let tabTitle, !tabTitle.isEmpty { return tabTitle }
    return subtitle ?? title
  }

  nonisolated var stateChangedDate: Date? {
    stateChangedAt.flatMap(MirrorConversationEvent.parseTimestamp)
  }
}
