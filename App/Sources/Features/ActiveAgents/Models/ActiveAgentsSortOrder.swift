import Foundation
import IdentifiedCollections

/// How the Active Agents panel orders its rows (docs-ai 092). The Agent Island roster and the
/// next/previous agent shortcuts follow the same order. `prowl agents` does not.
nonisolated enum ActiveAgentsSortOrder: String, CaseIterable, Codable, Equatable, Sendable {
  /// The order in which agents were first detected.
  case startTime
  /// One section per project, in the sidebar order.
  case project
  /// Blocked, then working, then done, then idle.
  case status

  var title: LocalizedStringResource {
    switch self {
    case .startTime: "Start Time"
    case .project: "Project"
    case .status: "Status"
    }
  }
}

/// A run of rows in the Active Agents panel. Only the `project` order gives a section a
/// project; a `nil` project in that order is the trailing "Other" section.
struct ActiveAgentSection: Equatable, Identifiable {
  enum Kind: Equatable, Hashable {
    /// The single, untitled section of the start-time and status orders.
    case all
    case project(Repository.ID)
    case other
  }

  let kind: Kind
  let entryIDs: [ActiveAgentEntry.ID]

  var id: Kind { kind }
}

enum ActiveAgentsOrdering {
  /// The sections to show, in order. `entries` is in start-time order.
  ///
  /// - Parameters:
  ///   - projectIDs: The project of each entry, for the `project` order. An entry without one
  ///     goes into the trailing "Other" section.
  ///   - projectOrder: The project IDs in sidebar order. A project that is not listed sorts
  ///     after the listed ones, in start-time order of its first agent.
  static func sections(
    entries: IdentifiedArrayOf<ActiveAgentEntry>,
    sortOrder: ActiveAgentsSortOrder,
    projectIDs: [ActiveAgentEntry.ID: Repository.ID],
    projectOrder: [Repository.ID]
  ) -> [ActiveAgentSection] {
    guard !entries.isEmpty else { return [] }
    switch sortOrder {
    case .startTime:
      return [ActiveAgentSection(kind: .all, entryIDs: entries.map(\.id))]
    case .status:
      // A stable sort: inside one status, rows keep their start-time order.
      let sorted = entries.enumerated().sorted { lhs, rhs in
        let lhsRank = statusRank(lhs.element.displayState)
        let rhsRank = statusRank(rhs.element.displayState)
        return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.offset < rhs.offset
      }
      return [ActiveAgentSection(kind: .all, entryIDs: sorted.map(\.element.id))]
    case .project:
      return projectSections(entries: entries, projectIDs: projectIDs, projectOrder: projectOrder)
    }
  }

  /// The entries in display order, for keyboard navigation and the Agent Island roster.
  static func orderedEntries(
    entries: IdentifiedArrayOf<ActiveAgentEntry>,
    sections: [ActiveAgentSection]
  ) -> IdentifiedArrayOf<ActiveAgentEntry> {
    IdentifiedArray(
      uncheckedUniqueElements: sections.flatMap(\.entryIDs).compactMap { entries[id: $0] }
    )
  }

  private static func projectSections(
    entries: IdentifiedArrayOf<ActiveAgentEntry>,
    projectIDs: [ActiveAgentEntry.ID: Repository.ID],
    projectOrder: [Repository.ID]
  ) -> [ActiveAgentSection] {
    var entryIDsByProject: [Repository.ID: [ActiveAgentEntry.ID]] = [:]
    var unlistedProjects: [Repository.ID] = []
    var otherEntryIDs: [ActiveAgentEntry.ID] = []
    let listedProjects = Set(projectOrder)
    for entry in entries {
      guard let projectID = projectIDs[entry.id] else {
        otherEntryIDs.append(entry.id)
        continue
      }
      if entryIDsByProject[projectID] == nil, !listedProjects.contains(projectID) {
        unlistedProjects.append(projectID)
      }
      entryIDsByProject[projectID, default: []].append(entry.id)
    }
    var sections = (projectOrder + unlistedProjects).compactMap { projectID in
      entryIDsByProject[projectID].map {
        ActiveAgentSection(kind: .project(projectID), entryIDs: $0)
      }
    }
    if !otherEntryIDs.isEmpty {
      sections.append(ActiveAgentSection(kind: .other, entryIDs: otherEntryIDs))
    }
    return sections
  }

  private static func statusRank(_ state: AgentDisplayState) -> Int {
    switch state {
    case .blocked: 0
    case .working: 1
    case .done: 2
    case .idle: 3
    }
  }
}
