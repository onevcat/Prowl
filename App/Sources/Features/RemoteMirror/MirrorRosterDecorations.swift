import Foundation

/// How the Mac sidebar shows each project, for the Mirror pane roster (docs-ai 089): the
/// sidebar name, the repository color, the position and the holding group. The app pushes it
/// from the repositories state; the pane source reads it on every list.
nonisolated struct MirrorRosterDecorations: Equatable, Sendable {
  struct Project: Equatable, Sendable {
    var title: String?
    var color: String?
    var order: Int
    var group: String?
  }

  private(set) var projects: [Repository.ID: Project] = [:]

  init() {}

  init(
    layout: SidebarLayout,
    appearances: [Repository.ID: RepositoryAppearance],
    customTitles: [Repository.ID: String]
  ) {
    var order = 0
    for item in layout.items {
      let group: RepositoryGroup? =
        if case .group(let group) = item { group } else { nil }
      for id in item.repositoryIDs where projects[id] == nil {
        let title = customTitles[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        projects[id] = Project(
          title: title?.isEmpty == false ? title : nil,
          color: Self.wireColor(appearances[id]?.color),
          order: order,
          group: group?.title)
        order += 1
      }
    }
  }

  func project(for id: Repository.ID) -> Project? { projects[id] }

  /// A preset as its name, a custom color as `#RRGGBB`.
  static func wireColor(_ choice: RepositoryColorChoice?) -> String? {
    switch choice {
    case nil: nil
    case .red: "red"
    case .orange: "orange"
    case .yellow: "yellow"
    case .green: "green"
    case .mint: "mint"
    case .cyan: "cyan"
    case .blue: "blue"
    case .purple: "purple"
    case .pink: "pink"
    case .gray: "gray"
    case .custom(let tint):
      String(
        format: "#%02X%02X%02X", Self.channel(tint.red), Self.channel(tint.green), Self.channel(tint.blue))
    }
  }

  private static func channel(_ value: Double) -> Int {
    Int((min(max(value, 0), 1) * 255).rounded())
  }
}
