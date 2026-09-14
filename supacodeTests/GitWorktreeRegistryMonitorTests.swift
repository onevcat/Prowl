import Foundation
import Testing

@testable import supacode

@MainActor
struct GitWorktreeRegistryMonitorTests {
  @Test func watchesGitdirFileOfEveryRegistryEntry() throws {
    let layout = try RegistryLayout(entries: ["sparrow": .withGitdir, "swift": .withGitdir])
    defer { layout.remove() }

    let urls = GitWorktreeRegistryMonitor.registryEntryURLs(
      inWorktreesDirectory: layout.worktreesDirectoryURL,
      fileManager: .default
    )

    #expect(urls == [layout.gitdirURL(for: "sparrow"), layout.gitdirURL(for: "swift")])
  }

  @Test func fallsBackToEntryDirectoryWhenGitdirIsNotWrittenYet() throws {
    let layout = try RegistryLayout(entries: ["sparrow": .withGitdir, "swift": .directoryOnly])
    defer { layout.remove() }

    let urls = GitWorktreeRegistryMonitor.registryEntryURLs(
      inWorktreesDirectory: layout.worktreesDirectoryURL,
      fileManager: .default
    )

    #expect(urls == [layout.gitdirURL(for: "sparrow"), layout.entryURL(for: "swift")])
  }

  @Test func ignoresFilesSittingDirectlyInTheWorktreesDirectory() throws {
    let layout = try RegistryLayout(entries: ["sparrow": .withGitdir])
    defer { layout.remove() }
    try Data().write(to: layout.worktreesDirectoryURL.appending(path: "stray-file"))

    let urls = GitWorktreeRegistryMonitor.registryEntryURLs(
      inWorktreesDirectory: layout.worktreesDirectoryURL,
      fileManager: .default
    )

    #expect(urls == [layout.gitdirURL(for: "sparrow")])
  }

  @Test func returnsNoTargetsWhenTheRegistryDirectoryIsAbsent() throws {
    let layout = try RegistryLayout(entries: [:], createWorktreesDirectory: false)
    defer { layout.remove() }

    let urls = GitWorktreeRegistryMonitor.registryEntryURLs(
      inWorktreesDirectory: layout.worktreesDirectoryURL,
      fileManager: .default
    )

    #expect(urls.isEmpty)
  }
}

private struct RegistryLayout {
  enum Entry {
    case withGitdir
    case directoryOnly
  }

  let rootURL: URL
  let worktreesDirectoryURL: URL

  init(entries: [String: Entry], createWorktreesDirectory: Bool = true) throws {
    rootURL = FileManager.default.temporaryDirectory
      .appending(path: "registry-monitor-\(UUID().uuidString)")
    worktreesDirectoryURL = rootURL.appending(path: ".git").appending(path: "worktrees")
    if createWorktreesDirectory {
      try FileManager.default.createDirectory(at: worktreesDirectoryURL, withIntermediateDirectories: true)
    } else {
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
    for (name, entry) in entries {
      try FileManager.default.createDirectory(at: entryURL(for: name), withIntermediateDirectories: true)
      if entry == .withGitdir {
        try Data("\(rootURL.path(percentEncoded: false))/\(name)/.git\n".utf8)
          .write(to: gitdirURL(for: name))
      }
    }
  }

  func entryURL(for name: String) -> URL {
    worktreesDirectoryURL.appending(path: name).standardizedFileURL
  }

  func gitdirURL(for name: String) -> URL {
    entryURL(for: name).appending(path: "gitdir").standardizedFileURL
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
