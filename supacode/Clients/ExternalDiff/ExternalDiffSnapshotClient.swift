import ComposableArchitecture
import Foundation

nonisolated struct ExternalDiffSnapshotPair: Equatable, Sendable {
  let leftURL: URL
  let rightURL: URL
}

nonisolated struct ExternalDiffSnapshotClient: Sendable {
  var makeSnapshotPair: @Sendable (_ workingDirectory: URL) async throws -> ExternalDiffSnapshotPair
}

extension ExternalDiffSnapshotClient: DependencyKey {
  static let liveValue = ExternalDiffSnapshotClient { workingDirectory in
    try await ExternalDiffSnapshotBuilder().makeSnapshotPair(at: workingDirectory)
  }

  static let testValue = ExternalDiffSnapshotClient { _ in
    ExternalDiffSnapshotPair(
      leftURL: URL(fileURLWithPath: "/tmp/prowl-diff-left"),
      rightURL: URL(fileURLWithPath: "/tmp/prowl-diff-right")
    )
  }
}

extension DependencyValues {
  var externalDiffSnapshotClient: ExternalDiffSnapshotClient {
    get { self[ExternalDiffSnapshotClient.self] }
    set { self[ExternalDiffSnapshotClient.self] = newValue }
  }
}

private nonisolated struct ExternalDiffSnapshotBuilder {
  func makeSnapshotPair(at workingDirectory: URL) async throws -> ExternalDiffSnapshotPair {
    let git = try await GitExecutableResolver.shared.resolve()
    let gitClient = GitClient()
    async let trackedOutput = gitClient.diffNameStatus(at: workingDirectory)
    async let untrackedPaths = gitClient.untrackedFilePaths(at: workingDirectory)
    let trackedFiles = DiffChangedFile.parseNameStatus(await trackedOutput)
    let untrackedFiles = await untrackedPaths.map {
      DiffChangedFile(status: .added, oldPath: nil, newPath: $0)
    }
    let files = trackedFiles + untrackedFiles

    return try await Task.detached {
      let rootURL = FileManager.default.temporaryDirectory
        .appending(path: "ProwlDiffSnapshots")
        .appending(path: UUID().uuidString)
      let leftURL = rootURL.appending(path: "HEAD")
      let rightURL = rootURL.appending(path: "Worktree")
      try FileManager.default.createDirectory(at: leftURL, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: rightURL, withIntermediateDirectories: true)

      for file in files {
        try copySnapshotFile(file, from: workingDirectory, leftURL: leftURL, rightURL: rightURL, git: git)
      }

      return ExternalDiffSnapshotPair(leftURL: leftURL, rightURL: rightURL)
    }.value
  }

  private func copySnapshotFile(
    _ file: DiffChangedFile,
    from worktreeURL: URL,
    leftURL: URL,
    rightURL: URL,
    git: GitExecutable
  ) throws {
    if let oldPath = file.oldPath {
      try writeHeadFile(oldPath, worktreeURL: worktreeURL, destinationRoot: leftURL, git: git)
    }
    if let newPath = file.newPath {
      let sourceURL = worktreeURL.appending(path: newPath)
      guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
        return
      }
      let destinationURL = rightURL.appending(path: newPath)
      try createParentDirectory(for: destinationURL)
      if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
        try FileManager.default.removeItem(at: destinationURL)
      }
      try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
  }

  private func writeHeadFile(
    _ relativePath: String,
    worktreeURL: URL,
    destinationRoot: URL,
    git: GitExecutable
  ) throws {
    let destinationURL = destinationRoot.appending(path: relativePath)
    try createParentDirectory(for: destinationURL)
    if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    FileManager.default.createFile(atPath: destinationURL.path(percentEncoded: false), contents: nil)
    let outputHandle = try FileHandle(forWritingTo: destinationURL)
    defer { try? outputHandle.close() }

    let process = Process()
    process.executableURL = git.url
    process.environment = ProcessInfo.processInfo.environment.merging(git.environment) { _, selected in selected }
    process.arguments = [
      "-C",
      worktreeURL.path(percentEncoded: false),
      "show",
      "HEAD:\(relativePath)",
    ]
    process.standardOutput = outputHandle
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw ExternalDiffSnapshotError.gitShowFailed(relativePath)
    }
  }

  private func createParentDirectory(for fileURL: URL) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
  }
}

private nonisolated enum ExternalDiffSnapshotError: Error {
  case gitShowFailed(String)
}
