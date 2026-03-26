enum CanvasCardTitleSegment: Equatable, Sendable {
  case repositoryName
  case currentDirectory
  case worktreeName
}

enum CanvasCardTitleLayoutPriority {
  static let repositoryName: Double = 3
  static let currentDirectory: Double = 2
  static let worktreeName: Double = 1

  static let compressionOrder: [CanvasCardTitleSegment] = [
    .worktreeName,
    .currentDirectory,
    .repositoryName,
  ]

  struct Allocation: Equatable, Sendable {
    let repositoryCharacters: Int
    let currentDirectoryCharacters: Int?
    let worktreeCharacters: Int?
  }

  static func allocation(
    repositoryName: String,
    currentDirectory: String?,
    worktreeName: String?,
    maxCharacters: Int
  ) -> Allocation {
    var repositoryCharacters = repositoryName.count
    var currentDirectoryCharacters = currentDirectory.map(\.count)
    var worktreeCharacters = worktreeName.map(\.count)

    let segments = [repositoryName, currentDirectory, worktreeName].compactMap { $0 }
    let separatorCharacters = max(0, segments.count - 1)
    var totalCharacters =
      repositoryCharacters + (currentDirectoryCharacters ?? 0) + (worktreeCharacters ?? 0) + separatorCharacters
    let budget = max(0, maxCharacters)

    for segment in compressionOrder {
      while totalCharacters > budget {
        var didReduce = false
        switch segment {
        case .worktreeName:
          if let count = worktreeCharacters, count > 1 {
            worktreeCharacters = count - 1
            totalCharacters -= 1
            didReduce = true
          }
        case .currentDirectory:
          if let count = currentDirectoryCharacters, count > 1 {
            currentDirectoryCharacters = count - 1
            totalCharacters -= 1
            didReduce = true
          }
        case .repositoryName:
          if repositoryCharacters > 1 {
            repositoryCharacters -= 1
            totalCharacters -= 1
            didReduce = true
          }
        }
        if !didReduce {
          break
        }
      }
      if totalCharacters <= budget {
        break
      }
    }

    return Allocation(
      repositoryCharacters: repositoryCharacters,
      currentDirectoryCharacters: currentDirectoryCharacters,
      worktreeCharacters: worktreeCharacters
    )
  }
}
