import Foundation

struct DetailToolbarTitle: Equatable {
  enum Kind: Equatable {
    case branch(name: String)
    case folder(name: String)
    case workspace(name: String)
  }

  let kind: Kind

  var text: String {
    switch kind {
    case .branch(let name), .folder(let name), .workspace(let name):
      return name
    }
  }

  var systemImage: String {
    switch kind {
    case .branch:
      return "arrow.trianglehead.branch"
    case .workspace:
      return "folder.badge.person.crop"
    case .folder:
      return "folder"
    }
  }

  var supportsRename: Bool {
    if case .branch = kind {
      return true
    }
    return false
  }

  static func forSelection(
    worktree: Worktree?,
    repository: Repository?
  ) -> DetailToolbarTitle? {
    if let worktree {
      return DetailToolbarTitle(kind: .branch(name: worktree.name))
    }
    guard let repository, repository.kind == .plain else {
      return nil
    }
    if repository.isWorkspace {
      return DetailToolbarTitle(kind: .workspace(name: repository.name))
    }
    return DetailToolbarTitle(kind: .folder(name: repository.name))
  }
}
