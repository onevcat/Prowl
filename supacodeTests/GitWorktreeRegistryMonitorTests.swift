import Foundation
import Testing
import XCTest

@testable import supacode

@Suite(.serialized)
@MainActor
struct GitWorktreeRegistryMonitorTests {
  @Test func observesGitWorktreeMoves() async throws {
    let layout = try RegistryLayout(entries: [:])
    defer { layout.remove() }
    try layout.initializeGitWorktrees()
    let events = RegistryEvents()
    let monitor = try #require(GitWorktreeRegistryMonitor(repositoryRootURL: layout.rootURL, onEvent: events.record))
    defer { monitor.cancel() }

    try await events.expectEvent {
      try layout.git(["worktree", "move", "sparrow", "moved"])
    }
    try await events.expectEvent {
      try layout.git(["worktree", "move", "moved", "moved-again"])
    }
  }

  @Test func observesMovesAfterAtomicGitdirReplacement() async throws {
    let layout = try RegistryLayout(entries: [:])
    defer { layout.remove() }
    try layout.initializeGitWorktrees()
    let events = RegistryEvents()
    let monitor = try #require(GitWorktreeRegistryMonitor(repositoryRootURL: layout.rootURL, onEvent: events.record))
    defer { monitor.cancel() }

    try await events.expectEvent {
      let url = layout.gitdirURL(for: "sparrow")
      try Data(contentsOf: url).write(to: url, options: .atomic)
    }
    try await events.expectEvent {
      try layout.git(["worktree", "move", "sparrow", "moved"])
    }
    try await events.expectEvent {
      try layout.git(["worktree", "move", "moved", "moved-again"])
    }
  }

  @Test func observesMovesAfterSameNameRecreation() async throws {
    let layout = try RegistryLayout(entries: [:])
    defer { layout.remove() }
    try layout.initializeGitWorktrees()
    let events = RegistryEvents()
    let monitor = try #require(GitWorktreeRegistryMonitor(repositoryRootURL: layout.rootURL, onEvent: events.record))
    defer { monitor.cancel() }

    try await events.expectEvent {
      // Do not yield the main actor between removal and recreation. The other worktree
      // keeps the registry directory alive while the entry gets a new inode.
      try layout.git(["worktree", "remove", "sparrow"])
      try layout.git(["worktree", "add", "sparrow", "sparrow"])
    }
    try await events.expectEvent {
      try layout.git(["worktree", "move", "sparrow", "moved"])
    }
    try await events.expectEvent {
      try layout.git(["worktree", "move", "moved", "moved-again"])
    }
  }

  @Test func promotesDirectoryWatchWhenGitdirAppears() async throws {
    let layout = try RegistryLayout(entries: ["sparrow": .directoryOnly])
    defer { layout.remove() }
    let events = RegistryEvents()
    let monitor = try #require(GitWorktreeRegistryMonitor(repositoryRootURL: layout.rootURL, onEvent: events.record))
    defer { monitor.cancel() }

    try await events.expectEvent {
      try Data("first\n".utf8).write(to: layout.gitdirURL(for: "sparrow"))
    }
    try await events.expectEvent {
      try Data("second\n".utf8).write(to: layout.gitdirURL(for: "sparrow"))
    }
  }

  @Test func observesNewEntriesAfterRegistryDirectoryRecreation() async throws {
    let layout = try RegistryLayout(entries: ["sparrow": .withGitdir])
    defer { layout.remove() }
    let events = RegistryEvents()
    let monitor = try #require(GitWorktreeRegistryMonitor(repositoryRootURL: layout.rootURL, onEvent: events.record))
    defer { monitor.cancel() }

    try await events.expectEvent {
      // Removing the last worktree can remove the registry directory too.
      try FileManager.default.removeItem(at: layout.worktreesDirectoryURL)
      try FileManager.default.createDirectory(at: layout.entryURL(for: "sparrow"), withIntermediateDirectories: true)
      try Data("recreated\n".utf8).write(to: layout.gitdirURL(for: "sparrow"))
    }
    try await events.expectEvent {
      try FileManager.default.createDirectory(at: layout.entryURL(for: "swift"), withIntermediateDirectories: true)
      try Data("new-entry\n".utf8).write(to: layout.gitdirURL(for: "swift"))
    }
    try await events.expectEvent {
      try Data("moved\n".utf8).write(to: layout.gitdirURL(for: "swift"))
    }
  }

  @Test func cancellationDoesNotRecreateEntryWatches() async throws {
    let layout = try RegistryLayout(entries: ["sparrow": .withGitdir])
    defer { layout.remove() }
    let events = RegistryEvents()
    let monitor = try #require(GitWorktreeRegistryMonitor(repositoryRootURL: layout.rootURL, onEvent: events.record))
    try Data("replacement\n".utf8).write(to: layout.gitdirURL(for: "sparrow"), options: .atomic)
    monitor.cancel()
    monitor.cancel()
    await events.drainEvents()
    try Data("after-cancel\n".utf8).write(to: layout.gitdirURL(for: "sparrow"))
    await events.drainEvents()
    #expect(events.count == 0)
  }

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

@MainActor
private final class RegistryEvents {
  private var pendingEvent: XCTestExpectation?
  private(set) var count = 0

  func record() {
    count += 1
    pendingEvent?.fulfill()
    pendingEvent = nil
  }

  func expectEvent(_ operation: () throws -> Void) async throws {
    await drainEvents()
    let event = XCTestExpectation(description: "Registry change")
    pendingEvent = event
    defer { pendingEvent = nil }
    try operation()
    let result = await XCTWaiter.fulfillment(of: [event], timeout: 2)
    #expect(result == .completed)
  }

  func drainEvents() async {
    // Vnode delivery uses the OS queue, not a test clock. Let prior events settle
    // before arming an expectation so they cannot satisfy the next operation.
    await withCheckedContinuation { continuation in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        continuation.resume()
      }
    }
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

  func initializeGitWorktrees() throws {
    try git(["init"])
    try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "Initial"])
    try git(["worktree", "add", "-b", "sparrow", "sparrow"])
    try git(["worktree", "add", "-b", "swift", "swift"])
  }

  func git(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments =
      [
        "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
        "-C", rootURL.path(percentEncoded: false),
      ] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "Git command failed: \(arguments)")
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
