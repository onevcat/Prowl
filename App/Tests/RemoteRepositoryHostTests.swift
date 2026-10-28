import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import Prowl

/// The remote host of `RepositoryHost` (docs-ai 084 B3b). The lane of these tests runs
/// `sh -s` and `bash -s` on this Mac, so the remote commands meet a real git repository,
/// and their results are compared with the local `GitClient` on the same repository.
struct RemoteRepositoryHostTests {
  // MARK: - Command lines

  @Test func anEnvCommandLineBecomesARemoteCommandWithoutLocalPaths() {
    let command = RemoteGitShell.command(
      executable: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [
        "PATH=/opt/homebrew/bin:/usr/bin", "LC_ALL=C", "LANG=C", "DEVELOPER_DIR=/Applications/Xcode.app",
        "/usr/bin/git", "-C", "/srv/app", "remote",
      ],
      directory: nil)

    #expect(command.executable == "/usr/bin/git")
    #expect(command.arguments == ["-C", "/srv/app", "remote"])
    // The lane sets the login PATH; DEVELOPER_DIR names a folder on this Mac.
    #expect(command.environment.map(\.name) == ["LC_ALL", "LANG"])
    #expect(command.workingDirectory == nil)
  }

  @Test func outcomesMapAsALocalProcessWould() throws {
    let command = RemoteShellCommand(executable: "/usr/bin/git", arguments: ["status"])
    func exited(_ code: Int32, _ errorOutput: String = "") -> RemoteCommandOutcome {
      .exited(
        RemoteCommandResult(exitCode: code, output: Data("out".utf8), outputTruncated: false, errorOutput: errorOutput))
    }

    #expect(try RemoteGitShell.output(of: exited(0), command: command).stdout == "out")
    #expect(throws: ShellClientError(command: "/usr/bin/git status", stdout: "out", stderr: "fatal", exitCode: 128)) {
      try RemoteGitShell.output(of: exited(128, "fatal"), command: command)
    }
    #expect(throws: RemoteRepositoryHostError.connection(.unreachable)) {
      try RemoteGitShell.output(of: exited(255, "ssh: connect to host mini: Connection refused"), command: command)
    }
    #expect(throws: RemoteRepositoryHostError.timedOut) { try RemoteGitShell.output(of: .timedOut, command: command) }
    // Git can exit 255 itself; without one of ssh's messages it stays a git failure.
    #expect(throws: ShellClientError(command: "/usr/bin/git status", stdout: "out", stderr: "error: x", exitCode: 255))
    {
      try RemoteGitShell.output(of: exited(255, "error: x"), command: command)
    }
    let truncated = RemoteCommandOutcome.exited(
      RemoteCommandResult(exitCode: 0, output: Data("out".utf8), outputTruncated: true, errorOutput: ""))
    #expect(throws: RemoteRepositoryHostError.outputTooLarge) {
      try RemoteGitShell.output(of: truncated, command: command)
    }
  }

  @Test func gitIsResolvedOnceOnTheHost() async throws {
    let runs = LockIsolated(0)
    let lane = RemoteCommandLane(
      run: { command, _ in
        runs.withValue { $0 += 1 }
        #expect(command.arguments.last?.hasSuffix("command -v git") == true)
        return .exited(
          RemoteCommandResult(
            exitCode: 0, output: Data("/usr/local/bin/git\n".utf8), outputTruncated: false, errorOutput: ""))
      },
      runScript: { _, _ in .timedOut })
    let executor = GitCommandExecutor.remote(lane: lane, limits: .commandLane)

    #expect(try await executor.resolveGit(false).url.path(percentEncoded: false) == "/usr/local/bin/git")
    _ = try await executor.resolveGit(false)
    #expect(runs.value == 1)
  }

  /// `sshd` dropping the connection (a restart, connection throttling) is a connection
  /// error, both while git is found and after.
  @Test func aConnectionResetByThePeerStaysAConnectionError() async throws {
    let reset = RemoteCommandOutcome.exited(
      RemoteCommandResult(
        exitCode: 255, output: Data(), outputTruncated: false,
        errorOutput: "kex_exchange_identification: read: Connection reset by peer"))
    let lane = RemoteCommandLane(run: { _, _ in reset }, runScript: { _, _ in reset })
    let cache = LockIsolated<GitExecutable?>(nil)
    let executor = GitCommandExecutor.remote(lane: lane, limits: .commandLane, gitCache: cache)

    await #expect(throws: RemoteRepositoryHostError.connection(.unreachable)) {
      _ = try await executor.resolveGit(false)
    }
    cache.setValue(GitExecutable(url: URL(filePath: "/usr/bin/git"), searchPath: ""))
    await #expect(throws: RemoteRepositoryHostError.connection(.unreachable)) {
      _ = try await GitClient(executor: executor).remoteNames(for: URL(filePath: "/srv/app"))
    }
  }

  /// A shell startup file on the host can print before every command; that text is not
  /// git's output.
  @Test func startupOutputOnTheHostIsNotReadAsGitOutput() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    try await fixture.git(["remote", "add", "origin", "git@github.com:example/app.git"])
    let linked = try await fixture.addWorktree("linked", branch: "side")
    let host = RepositoryHost(
      local: .testValue, remote: fixture.remoteClient(lane: GitFixture.localLane.printingAGreetingFirst()))
    let location = fixture.remoteLocation

    #expect(try await host.localBranchNames(in: location) == ["side", "trunk"])
    #expect(try await host.isBareRepository(location) == false)
    #expect(try await host.remoteNames(in: location) == ["origin"])
    #expect(await host.remoteInfo(for: location)?.owner == "example")
    #expect(try await host.untrackedFileCount(in: location) == 0)
    #expect(try await host.worktrees(in: location).count == 2)
    let worktree = try #require(try await host.worktrees(in: location).first { !$0.isMain })
    try await host.removeWorktree(worktree, deleteBranch: false)
    #expect(!FileManager.default.fileExists(atPath: linked.path))
  }

  @Test func aHostWithoutGitIsReported() async {
    let lane = RemoteCommandLane(
      run: { _, _ in
        .exited(RemoteCommandResult(exitCode: 127, output: Data(), outputTruncated: false, errorOutput: ""))
      },
      runScript: { _, _ in .timedOut })

    await #expect(throws: RemoteRepositoryHostError.gitMissing) {
      _ = try await GitCommandExecutor.remote(lane: lane, limits: .commandLane).resolveGit(false)
    }
  }

  // MARK: - Leases

  /// A configuration that now reaches another user must not run anything: the next
  /// command could remove a worktree on another machine.
  @Test func aLeasedLaneRunsNothingWhenTheHostAuthorityChanged() async {
    let commands = LockIsolated<[[String]]>([])
    let registry = Self.registry(resolvedUser: "someone-else", commands: commands)
    let lane = RemoteCommandLane.leased(Self.profile, registry: registry)

    await #expect(throws: RemoteRepositoryHostError.authorityChanged) {
      _ = try await lane.run(RemoteShellCommand(executable: "git", arguments: ["status"]), .commandLane)
    }
    #expect(commands.value.allSatisfy { $0.contains("-G") })
    #expect(await registry.leaseCount(Self.profile.connectionKey) == 0)
  }

  @Test func aLeasedLaneRunsAndReleasesWhenTheAuthorityIsUnchanged() async throws {
    let commands = LockIsolated<[[String]]>([])
    let registry = Self.registry(resolvedUser: "dev", commands: commands)
    let lane = RemoteCommandLane.leased(Self.profile, registry: registry)

    let outcome = try await lane.run(RemoteShellCommand(executable: "git", arguments: ["status"]), .commandLane)

    guard case .exited(let result) = outcome else {
      Issue.record("The command did not run")
      return
    }
    #expect(result.exitCode == 0)
    #expect(commands.value.contains { !$0.contains("-G") })
    #expect(await registry.leaseCount(Self.profile.connectionKey) == 0)
  }

  private static let profile = HostProfile(
    id: UUID(), alias: "mini", recipe: SSHConnectionRecipe(destination: "mini"),
    connectionKey: ConnectionKey(user: "dev", hostname: "mini.local"))

  /// `ssh -G` answers with `resolvedUser`; every other command exits 0.
  private static func registry(resolvedUser: String, commands: LockIsolated<[[String]]>) -> RemoteConnectionRegistry {
    let runner = RemoteCommandRunner(execute: { _, arguments, _, _, _ in
      commands.withValue { $0.append(arguments) }
      let output = arguments.contains("-G") ? "user \(resolvedUser)\nhostname mini.local\nport 22\n" : ""
      return .exited(
        RemoteCommandResult(exitCode: 0, output: Data(output.utf8), outputTruncated: false, errorOutput: ""))
    })
    return RemoteConnectionRegistry(
      configuration: RemoteConnectionOwner.Configuration(controlDirectory: "/tmp/prowl-b3b-tests"), runner: runner)
  }

  // MARK: - Host lookup

  @Test(.dependencies) func aMissingHostProfileIsReported() async {
    let hostProfileID = UUID()
    await withDependencies {
      $0.hostProfilesFileURL = URL(fileURLWithPath: "/tmp/prowl-hosts-\(UUID().uuidString).json")
    } operation: {
      await #expect(throws: RepositoryHostError.hostProfileMissing(hostProfileID)) {
        _ = try await RemoteRepositoryHostClient.liveValue.host(hostProfileID)
      }
    }
  }

  // MARK: - Operations against a real repository

  @Test func readsMatchTheLocalHostOnTheSameRepository() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let linked = try await fixture.addWorktree("linked", branch: "side")
    try await fixture.git(["remote", "add", "origin", "git@github.com:example/app.git"])
    try Data("new\n".utf8).write(to: fixture.main.appending(path: "untracked.txt"))
    let host = RepositoryHost(local: .testValue, remote: fixture.remoteClient)
    let location = fixture.remoteLocation
    let local = GitClient.local
    let root = fixture.main

    let worktrees = try await host.worktrees(in: location)
    // Both were created in the same second, which is the precision of the host's creation
    // times, so their order is git's order there.
    #expect(Set(worktrees.map(\.name)) == ["side", "trunk"])
    #expect(worktrees.first { $0.isMain }?.location == location)
    #expect(worktrees.first { !$0.isMain }?.location.path.hasSuffix("/\(linked.lastPathComponent)") == true)
    #expect(try await host.localBranchNames(in: location) == (try await local.localBranchNames(for: root)))
    #expect(try await host.branchRefs(in: location) == (try await local.branchRefs(for: root)))
    #expect(await host.isValidBranchName("feature/next", in: location))
    #expect(await host.isValidBranchName("bad..name", in: location) == false)
    #expect(await host.automaticWorktreeBaseRef(in: location) == (await local.automaticWorktreeBaseRef(for: root)))
    #expect(try await host.isBareRepository(location) == false)
    #expect(try await host.untrackedFileCount(in: location) == 1)
    #expect(try await host.ignoredFileCount(in: location) == (try await local.ignoredFileCount(for: root)))
    #expect(try await host.remoteNames(in: location) == ["origin"])
    #expect(await host.githubRemoteInfos(for: location) == (await local.githubRemoteInfos(for: root)))
    #expect(await host.remoteInfo(for: location)?.repo == "app")
    #expect(await host.repositoryWebURL(for: location) == URL(string: "https://github.com/example/app"))
  }

  @Test func changesRunOnTheHostRepository() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let upstream = try await fixture.makeUpstream()
    try await fixture.git(["remote", "add", "upstream", upstream.path])
    _ = try await fixture.addWorktree("linked", branch: "side")
    let host = RepositoryHost(local: .testValue, remote: fixture.remoteClient)
    let location = fixture.remoteLocation

    try await host.fetchRemote("upstream", in: location)
    #expect(try await host.branchRefs(in: location).contains("upstream/trunk"))

    let linked = try #require(try await host.worktrees(in: location).first { !$0.isMain })
    try await host.renameBranch(in: linked.location, to: "renamed")
    let renamed = try #require(try await host.worktrees(in: location).first { !$0.isMain })
    #expect(renamed.name == "renamed")

    try await host.removeWorktree(renamed, deleteBranch: true)
    #expect(try await host.worktrees(in: location).map(\.name) == ["trunk"])
    #expect(try await host.localBranchNames(in: location) == ["trunk"])
    #expect(!FileManager.default.fileExists(atPath: renamed.location.path))
    try await host.pruneWorktrees(in: location)
  }

  @Test func theDefaultBranchStaysProtectedAndAFailedReadStopsTheDeletion() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    try await fixture.git(["branch", "develop"])
    try await fixture.git(["branch", "topic"])
    try await fixture.git(["update-ref", "refs/remotes/origin/develop", "HEAD"])
    try await fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop"])
    let host = RepositoryHost(local: .testValue, remote: fixture.remoteClient)
    let location = fixture.remoteLocation

    #expect(try await host.deleteLocalBranch(named: "develop", in: location, force: true) == .protected)
    #expect(try await host.deleteLocalBranch(named: "nothing", in: location, force: true) == .notFound)

    // The connection drops while the default branch is read: nothing is deleted.
    let dropping = fixture.remoteClient(lane: GitFixture.localLane.failing { $0.arguments.contains("symbolic-ref") })
    await #expect(throws: RemoteRepositoryHostError.connection(.unreachable)) {
      _ = try await RepositoryHost(local: .testValue, remote: dropping)
        .deleteLocalBranch(named: "topic", in: location, force: true)
    }
    #expect(try await host.localBranchNames(in: location).contains("topic"))
    #expect(try await host.deleteLocalBranch(named: "topic", in: location, force: true) == .deleted)
  }

  @Test func aDroppedConnectionKeepsItsTypeAndDoesNotReadAsAnInvalidName() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let host = RepositoryHost(
      local: .testValue, remote: fixture.remoteClient(lane: GitFixture.localLane.failing { _ in true }))

    await #expect(throws: RemoteRepositoryHostError.connection(.unreachable)) {
      _ = try await host.remoteNames(in: fixture.remoteLocation)
    }
    #expect(await host.isValidBranchName("feature/next", in: fixture.remoteLocation))
  }

  @Test func aPathThatGitDoesNotListIsNotRemoved() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let host = RepositoryHost(local: .testValue, remote: fixture.remoteClient)
    let stray = fixture.root.appending(path: "stray", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: false)
    let worktree = Worktree(
      name: "stray", detail: "",
      location: RemoteRepositoryFixtures.location(stray.path(percentEncoded: false)),
      repositoryLocation: fixture.remoteLocation)

    do {
      try await host.removeWorktree(worktree, deleteBranch: false)
      Issue.record("A path that git does not list must not be removed")
    } catch let GitClientError.worktreeNotRegistered(path) {
      #expect(path == worktree.location.path)
    }
    #expect(FileManager.default.fileExists(atPath: stray.path))
  }

  @Test func aFailedGitCommandKeepsTheLocalErrorShape() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let host = RepositoryHost(local: .testValue, remote: fixture.remoteClient)

    do {
      try await host.fetchRemote("missing-remote", in: fixture.remoteLocation)
      Issue.record("A fetch from a remote that does not exist must fail")
    } catch let error as GitClientError {
      guard case .commandFailed(let command, let message) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(command.hasSuffix("fetch missing-remote"))
      #expect(message.contains("missing-remote"))
    }
  }

  // MARK: - Worktree creation

  /// The bundled `wt` runs on the host as it runs on this Mac: it copies untracked files,
  /// starts from the base ref, and reports the new worktree's path.
  @Test func aWorktreeIsCreatedOnTheHostWithTheBundledWt() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    try Data("note\n".utf8).write(to: fixture.main.appending(path: "notes.txt"))
    let host = RepositoryHost(
      local: .testValue, remote: fixture.remoteClient(lane: GitFixture.localLane.printingAGreetingFirst()))
    let location = fixture.remoteLocation
    let base = fixture.root.appending(path: "worktrees", directoryHint: .isDirectory)
    let request = GitWorktreeCreateRequest(
      name: "feature", repoRoot: URL(filePath: location.path), baseDirectory: base,
      copyFiles: .init(ignored: false, untracked: true), baseRef: "trunk")

    var lines: [ShellStreamLine] = []
    var created: Worktree?
    for try await event in host.createWorktreeStream(in: location, request) {
      switch event {
      case .outputLine(let line): lines.append(line)
      case .finished(let worktree): created = worktree
      }
    }

    let worktree = try #require(created)
    let path = fixture.root.path(percentEncoded: false).trimmingSuffix("/") + "/worktrees/feature"
    #expect(worktree.location == RemoteRepositoryFixtures.location(path))
    #expect(worktree.name == "feature")
    #expect(worktree.detail == "../worktrees/feature")
    #expect(worktree.repositoryLocation == location)
    #expect(!lines.contains { $0.text.contains("Welcome") || $0.text.hasPrefix("PROWL_") })
    // `wt --verbose` reports the copy on standard error as it runs.
    #expect(lines.contains { $0.source == .stderr && $0.text.contains("notes.txt") })
    #expect(FileManager.default.fileExists(atPath: path + "/notes.txt"))
    // The refresh lists it under the same ID.
    #expect(try await host.worktrees(in: location).contains { $0.id == worktree.id && $0.name == "feature" })
  }

  @Test func aDirectoryOverridePlacesTheWorktreeAndAFailureKeepsWtsMessage() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let host = RepositoryHost(local: .testValue, remote: fixture.remoteClient)
    let location = fixture.remoteLocation
    let override = fixture.root.appending(path: "custom/place", directoryHint: .isDirectory)
    var request = GitWorktreeCreateRequest(
      name: "topic", repoRoot: URL(filePath: location.path),
      baseDirectory: fixture.root.appending(path: "worktrees", directoryHint: .isDirectory),
      copyFiles: .init(ignored: false, untracked: false), baseRef: "", directoryOverride: override)

    var created: Worktree?
    for try await event in host.createWorktreeStream(in: location, request) {
      if case .finished(let worktree) = event { created = worktree }
    }
    #expect(created?.location.path.hasSuffix("/custom/place") == true)

    // A base ref that does not exist: `wt` refuses, and its message reaches the caller.
    request.name = "other"
    request.baseRef = "no-such-ref"
    request.directoryOverride = nil
    do {
      for try await _ in host.createWorktreeStream(in: location, request) {}
      Issue.record("A worktree from a base ref that does not exist must fail")
    } catch let failure as RemoteWorktreeCreationError {
      guard case GitClientError.commandFailed(let command, let message)? = failure.underlying as? GitClientError else {
        Issue.record("Unexpected error: \(failure.underlying)")
        return
      }
      #expect(command.hasPrefix("wt "))
      #expect(!message.isEmpty)
      // Nothing was registered, so there is nothing to clean up.
      #expect(failure.addedPath == nil)
    }
  }

  /// A failed `git worktree add` must stop `wt` under bash 3.2 (macOS) and bash 5 (most
  /// Linux hosts): nothing is copied, no result is reported, and the creation fails.
  /// Bash 5 comes from Homebrew; the case is skipped where it is not installed.
  @Test(arguments: ["/bin/bash", "/opt/homebrew/bin/bash"])
  func aFailedWorktreeAddStopsWtUnderEveryBash(bash: String) async throws {
    guard FileManager.default.isExecutableFile(atPath: bash) else { return }
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    try Data("note\n".utf8).write(to: fixture.main.appending(path: "notes.txt"))
    // A folder that is not empty: `git worktree add` refuses it.
    let occupied = fixture.root.appending(path: "occupied", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
    try Data("mine\n".utf8).write(to: occupied.appending(path: "keep.txt"))
    let host = RepositoryHost(local: .testValue, remote: fixture.remoteClient(lane: GitFixture.lane(bash: bash)))
    let request = GitWorktreeCreateRequest(
      name: "blocked", repoRoot: URL(filePath: fixture.remoteLocation.path),
      baseDirectory: fixture.root.appending(path: "worktrees", directoryHint: .isDirectory),
      copyFiles: .init(ignored: false, untracked: true), baseRef: "trunk", directoryOverride: occupied)

    var finished = false
    do {
      for try await event in host.createWorktreeStream(in: fixture.remoteLocation, request) {
        if case .finished = event { finished = true }
      }
      Issue.record("A failed git worktree add must fail the creation under \(bash)")
    } catch let failure as RemoteWorktreeCreationError {
      guard case GitClientError.commandFailed(let command, _)? = failure.underlying as? GitClientError else {
        Issue.record("Unexpected error: \(failure.underlying)")
        return
      }
      #expect(command.hasPrefix("wt "))
      #expect(failure.addedPath == nil)
    }

    #expect(!finished)
    #expect(!FileManager.default.fileExists(atPath: occupied.appending(path: "notes.txt").path))
    #expect(try await host.worktrees(in: fixture.remoteLocation).map(\.name) == ["trunk"])
  }

  /// Another creator on the host registers the same branch at the same destination just
  /// before this attempt's `git worktree add`. This attempt fails, and its cleanup must
  /// leave the winner's worktree and its uncommitted files alone.
  @Test(.dependencies) func aFailedCreationNeverRemovesAWorktreeThatAnotherCreatorAdded() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let wrapper = try fixture.gitWrapper(
      """
      if [ "$3" = worktree ] && [ "$4" = add ] && [ "$5" = -b ] && [ ! -e "$PROWL_TEST_ROOT/raced" ]; then
        touch "$PROWL_TEST_ROOT/raced"
        "$PROWL_REAL_GIT" -C "$2" worktree add -q -b "$6" "$7" "$8"
        echo dirty > "$7/keep-me.txt"
      fi
      """)
    let result = try await fixture.createThroughTheReducer(branch: "feature", wrapper: wrapper)

    #expect(result.failed)
    let winner = fixture.root.path(percentEncoded: false).trimmingSuffix("/") + "/worktrees/feature"
    #expect(FileManager.default.fileExists(atPath: winner + "/keep-me.txt"))
    #expect(try await result.host.worktrees(in: fixture.remoteLocation).contains { $0.location.path == winner })
  }

  /// The connection drops after this attempt's own `git worktree add`: the host
  /// reported the worktree it registered, so cleanup removes it.
  @Test(.dependencies) func aFailedCreationRemovesTheWorktreeThatItAdded() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let result = try await fixture.createThroughTheReducer(
      branch: "feature", lane: GitFixture.localLane.droppingTheConnectionAfterEachStream())

    #expect(result.failed)
    let path = fixture.root.path(percentEncoded: false).trimmingSuffix("/") + "/worktrees/feature"
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(try await result.host.worktrees(in: fixture.remoteLocation).map(\.name) == ["trunk"])
  }

  /// A remote worktree gets no automatic local shell, so its setup script never runs here.
  @MainActor @Test func aRemoteWorktreeGetsNoAutomaticLocalTab() async {
    let remote = RemoteRepositoryFixtures.gitRepository()
    let state = WorktreeTerminalState(runtime: GhosttyRuntime(), worktree: remote.worktrees[0])

    state.ensureInitialTab(focusing: false)
    await Task.yield()

    #expect(state.tabManager.tabs.isEmpty)
  }

  @Test func theHostHomeDirectoryIsReadOnce() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let reads = LockIsolated(0)
    let greeting = GitFixture.localLane.printingAGreetingFirst()
    let counting = RemoteCommandLane(
      run: { command, limits in
        if command.arguments.contains(where: { $0.contains("$HOME") }) { reads.withValue { $0 += 1 } }
        return try await greeting.run(command, limits)
      },
      runScript: { try await greeting.runScript($0, $1) })
    let host = RepositoryHost(local: .testValue, remote: fixture.remoteClient(lane: counting))

    async let first = host.remoteHomeDirectory(in: fixture.remoteLocation)
    async let second = host.remoteHomeDirectory(in: fixture.remoteLocation)
    let homes = try await [first, second]

    #expect(homes == [ProcessInfo.processInfo.environment["HOME"], ProcessInfo.processInfo.environment["HOME"]])
    #expect(try await host.remoteHomeDirectory(in: fixture.remoteLocation) == homes[0])
    #expect(reads.value == 1)
    #expect(try await host.remoteHomeDirectory(in: .local(fixture.main)) == nil)
  }

  @Test func hostPathsAreRelatedAsTextWithoutThisMacsRules() {
    #expect(RemotePaths.relativePath(from: "/private/tmp/app", to: "/private/tmp/worktrees/x") == "../worktrees/x")
    #expect(RemotePaths.relativePath(from: "/srv/app/", to: "/srv/app") == ".")
    #expect(RemotePaths.relativePath(from: "/srv/app", to: "/srv/app/./wt/../wt2") == "wt2")
    #expect(RemotePaths.relativePath(from: "/a/b/c", to: "/x") == "../../../x")
  }

  // MARK: - Placement and the creation flow (B3d)

  @Test func remoteWorktreesArePlacedByTheHostsHome() {
    let placement = WorktreePlacement.remote(repositoryPath: "/srv/app", homeDirectory: "/home/dev")

    #expect(
      placement.defaultBaseDirectory(globalDefaultPath: "/Users/me/worktrees", repositoryOverridePath: nil)
        .path(percentEncoded: false) == "/home/dev/.prowl/repos/app/")
    let override = { (path: String) in
      placement.defaultBaseDirectory(globalDefaultPath: nil, repositoryOverridePath: path).path(percentEncoded: false)
    }
    #expect(override("~/wt") == "/home/dev/wt/")
    #expect(override("~") == "/home/dev/")
    #expect(override("../wt") == "/srv/wt/")
    #expect(override("/data/./wt/") == "/data/wt/")
    let base = URL(filePath: "/home/dev/.prowl/repos/app", directoryHint: .isDirectory)
    #expect(
      placement.resolvedDirectory(defaultBaseDirectory: base, nameOverride: " ", pathOverride: "", branchName: "x")
        == nil)
    #expect(
      placement.resolvedDirectory(
        defaultBaseDirectory: base, nameOverride: "leaf", pathOverride: "~/p", branchName: "x")?
        .path(percentEncoded: false) == "/home/dev/p/leaf/")
    #expect(
      placement.previewDirectory(defaultBaseDirectory: base, nameOverride: "", pathOverride: "", branchName: "feat/x")
        .path(percentEncoded: false) == "/home/dev/.prowl/repos/app/feat/x/")
  }

  @Test func remoteRepositoryFolderNamesAndAnotherUsersHome() {
    #expect(WorktreePlacement.repositoryDirectoryName("/srv/app/") == "app")
    #expect(WorktreePlacement.repositoryDirectoryName("/private/var/repos/app/.bare") == "private_var_repos_app_.bare")
    #expect(WorktreePlacement.repositoryDirectoryName("/") == "_")
    #expect(WorktreePlacement.namesAnotherUsersHome("~deploy/worktrees"))
    #expect(!WorktreePlacement.namesAnotherUsersHome("~/worktrees"))
    #expect(!WorktreePlacement.namesAnotherUsersHome("~"))
    #expect(!WorktreePlacement.namesAnotherUsersHome("/srv/~x"))
  }

  /// The prompt shows why the host's home could not be read, not a generic message.
  @Test(.dependencies) func thePromptShowsWhyTheHostCannotPlaceAWorktree() async throws {
    let refused = RemoteCommandOutcome.exited(
      RemoteCommandResult(
        exitCode: 255, output: Data(), outputTruncated: false, errorOutput: "dev@mini: Permission denied (publickey)."))
    let hostProfileID = RemoteRepositoryFixtures.hostProfileID
    let remote = RemoteRepositoryHost(
      hostProfileID: hostProfileID, lane: RemoteCommandLane(run: { _, _ in refused }, runScript: { _, _ in refused }))
    let repository = RemoteRepositoryFixtures.gitRepository()
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.promptForWorktreeCreation = true }
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteRepositoryHostClient.self] = RemoteRepositoryHostClient(host: { $0 == hostProfileID ? remote : nil })
    }
    store.exhaustivity = .off

    await store.send(.worktreeCreation(.createRandomWorktreeInRepository(repository.id)))
    await store.receive(\.worktreeCreation.promptLoadFailed, timeout: .seconds(30)) {
      $0.alert = RepositoriesFeature().messageAlert(
        title: "Unable to create worktree",
        message: """
          The remote host refused the SSH login. Prowl signs in only with a key or an SSH agent, \
          without a password prompt.
          """)
    }
    #expect(store.state.worktreeCreationPrompt == nil)
  }

  @Test(.dependencies) func aRemoteBaseDirectoryInAnotherUsersHomeIsRefused() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let location = fixture.remoteLocation
    let hostClient = fixture.remoteClient
    let repository = Repository(location: location, name: "main", worktrees: [])
    @Shared(.repositorySettings(location)) var repositorySettings
    $repositorySettings.withLock { $0.worktreeBaseDirectoryPath = "~deploy/worktrees" }
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0[RemoteRepositoryHostClient.self] = hostClient
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeCreation(
        .createWorktreeInRepository(
          repositoryID: repository.id, nameSource: .explicit("feature"), baseRefSource: .explicit("trunk"),
          fetchRemote: false)))
    await store.receive(\.worktreeCreation.createRandomWorktreeFailed, timeout: .seconds(60))
    await store.finish(timeout: .seconds(60))

    #expect(
      store.state.alert?.message.map { String(state: $0) }?.contains("another user's home (~deploy/worktrees)") == true)
    #expect(!FileManager.default.fileExists(atPath: fixture.main.path(percentEncoded: false) + "~deploy"))
  }

  /// A creation that registered its worktree and then failed is cleaned up on the host,
  /// also when its destination was placed through a link; a worktree of another branch
  /// at the destination is left alone.
  @Test(.dependencies) func aFailedRemoteCreationRemovesOnlyItsOwnWorktree() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let location = fixture.remoteLocation
    let hostClient = fixture.remoteClient
    let host = RepositoryHost(local: .testValue, remote: hostClient)
    let real = fixture.root.appending(path: "real", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    let link = fixture.root.path(percentEncoded: false).trimmingSuffix("/") + "/link"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real.path(percentEncoded: false))
    let ours = try await fixture.addWorktree("real/ours", branch: "ours")
    _ = try await fixture.addWorktree("real/theirs", branch: "theirs")
    var state = RepositoriesFeature.State()
    state.repositories = [
      Repository(
        location: location, name: "main",
        worktrees: IdentifiedArray(uniqueElements: try await host.worktrees(in: location)))
    ]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteRepositoryHostClient.self] = hostClient
    }
    store.exhaustivity = .off

    for (branch, folder) in [("ours", "ours"), ("not-theirs", "theirs")] {
      await store.send(
        .worktreeCreation(
          .createRandomWorktreeFailed(
            title: "Unable to create worktree", message: "boom", pendingID: "pending:\(branch)",
            previousSelection: nil, repositoryID: location.id, repositoryLocation: location, name: branch,
            worktreeLocation: RemoteRepositoryFixtures.location(link + "/" + folder))))
      await store.finish(timeout: .seconds(60))
    }

    let names = Set(try await host.worktrees(in: location).map(\.name))
    #expect(names == ["trunk", "theirs"])
    #expect(!FileManager.default.fileExists(atPath: ours.path(percentEncoded: false)))
  }

  /// The creation flow of the reducer runs on the remote host: placement under the
  /// repository's own setting (a host path), `wt` on the host, and the new worktree by its
  /// host path. The local git client is never asked.
  @Test(.dependencies) func theReducerCreatesAWorktreeInARemoteRepository() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let location = fixture.remoteLocation
    let hostClient = fixture.remoteClient
    let host = RepositoryHost(local: .testValue, remote: hostClient)
    let repository = Repository(
      location: location, name: "main",
      worktrees: IdentifiedArray(uniqueElements: try await host.worktrees(in: location)))
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = false
    }
    @Shared(.repositorySettings(location)) var repositorySettings
    $repositorySettings.withLock { $0.worktreeBaseDirectoryPath = "../worktrees" }
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0[RemoteRepositoryHostClient.self] = hostClient
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeCreation(
        .createWorktreeInRepository(
          repositoryID: repository.id, nameSource: .explicit("feature"), baseRefSource: .explicit("trunk"),
          fetchRemote: false)))
    await store.receive(\.worktreeCreation.createRandomWorktreeSucceeded, timeout: .seconds(60))
    await store.finish(timeout: .seconds(60))

    let path = fixture.root.path(percentEncoded: false).trimmingSuffix("/") + "/worktrees/feature"
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(store.state.repositories[id: repository.id]?.worktrees.contains { $0.location.path == path } == true)
  }

  // MARK: - Loading through the host (B3e)

  @Test(.dependencies) func remoteFoldersLoadTheirWorktreesThroughTheHost() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    _ = try await fixture.addWorktree("linked", branch: "side")
    let plain = fixture.root.appending(path: "notes", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
    let plainLocation = RemoteRepositoryFixtures.location(plain.path(percentEncoded: false).trimmingSuffix("/"))
    let entries = [
      PersistedRepositoryEntry(path: fixture.remoteLocation.id, kind: .git),
      PersistedRepositoryEntry(path: plainLocation.id, kind: .plain),
    ]
    let feature = withDependencies {
      $0[RemoteRepositoryHostClient.self] = fixture.remoteClient
      $0.continuousClock = TestClock()
    } operation: {
      RepositoriesFeature()
    }

    let (loaded, failures) = await feature.loadRepositoriesData(entries)

    #expect(failures.isEmpty)
    #expect(loaded.map(\.id) == [fixture.remoteLocation.id, plainLocation.id])
    #expect(loaded[0].kind == .git)
    #expect(loaded[0].name == "main")
    #expect(Set(loaded[0].worktrees.map(\.name)) == ["trunk", "side"])
    #expect(loaded[0].worktrees.first { $0.isMain }?.location == fixture.remoteLocation)
    #expect(loaded[1].kind == .plain)
    #expect(loaded[1].name == "notes")
  }

  /// A host that cannot be reached marks the failure, so the sidebar can say so (C1); a
  /// folder that is not a repository is a plain failure.
  @Test(.dependencies) func aRemoteFolderThatCannotLoadSaysWhetherTheHostIsUnreachable() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let plain = fixture.root.appending(path: "plain", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
    let notGit = RemoteRepositoryFixtures.location(plain.path(percentEncoded: false).trimmingSuffix("/"))
    let refused = RemoteCommandOutcome.exited(
      RemoteCommandResult(
        exitCode: 255, output: Data(), outputTruncated: false,
        errorOutput: "ssh: connect to host mini port 22: Connection refused"))
    let unreachableClient = fixture.remoteClient(
      lane: RemoteCommandLane(run: { _, _ in refused }, runScript: { _, _ in refused }))
    func load(_ client: RemoteRepositoryHostClient, _ location: RepositoryLocation) async
      -> [RepositoriesFeature.LoadFailure]
    {
      let feature = withDependencies {
        $0[RemoteRepositoryHostClient.self] = client
        $0.continuousClock = TestClock()
      } operation: {
        RepositoriesFeature()
      }
      return await feature.loadRepositoriesData([PersistedRepositoryEntry(path: location.id, kind: .git)]).1
    }

    let unreachable = await load(unreachableClient, fixture.remoteLocation)
    let notARepository = await load(fixture.remoteClient, notGit)

    #expect(unreachable.map(\.isHostUnreachable) == [true])
    #expect(unreachable.first?.message == "The remote host could not be reached.")
    #expect(notARepository.map(\.isHostUnreachable) == [false])
    #expect(notARepository.first?.message == "The folder on the remote host is not a Git repository.")
  }

  /// A host that does not answer holds back the load only until the deadline, then the
  /// folder fails as unreachable.
  @Test(.dependencies) func aHostThatDoesNotAnswerFailsTheLoadAtTheDeadline() async throws {
    let clock = TestClock()
    let hanging = RemoteCommandLane(
      run: { _, _ in
        try await Task.never()
        return .timedOut
      },
      runScript: { _, _ in
        try await Task.never()
        return .timedOut
      })
    let hostProfileID = RemoteRepositoryFixtures.hostProfileID
    let remote = RemoteRepositoryHost(hostProfileID: hostProfileID, lane: hanging)
    let feature = withDependencies {
      $0[RemoteRepositoryHostClient.self] = RemoteRepositoryHostClient(host: { $0 == hostProfileID ? remote : nil })
      $0.continuousClock = clock
    } operation: {
      RepositoriesFeature()
    }
    let location = RemoteRepositoryFixtures.location("/srv/app")

    let load = Task { await feature.loadRepositoriesData([PersistedRepositoryEntry(path: location.id, kind: .git)]) }
    // Let the load reach its deadline sleep before the clock moves.
    await Task.megaYield()
    await clock.advance(by: RepositoriesFeature.remoteLoadDeadline)
    let (loaded, failures) = await load.value

    #expect(loaded.isEmpty)
    #expect(failures.map(\.isHostUnreachable) == [true])
    #expect(failures.first?.message == "The remote host did not answer in time.")
  }

  /// A wait that ignores cancellation, as the shared read of the login `PATH` does, must
  /// not hold the load past its deadline.
  @Test(.dependencies) func theDeadlineDoesNotWaitForAnOperationThatIgnoresCancellation() async throws {
    let clock = TestClock()
    let gate = CancellationIgnoringGate()
    let stuck = RemoteCommandLane(
      run: { _, _ in
        await gate.wait()
        return .timedOut
      },
      runScript: { _, _ in
        await gate.wait()
        return .timedOut
      })
    let hostProfileID = RemoteRepositoryFixtures.hostProfileID
    let remote = RemoteRepositoryHost(hostProfileID: hostProfileID, lane: stuck)
    let feature = withDependencies {
      $0[RemoteRepositoryHostClient.self] = RemoteRepositoryHostClient(host: { $0 == hostProfileID ? remote : nil })
      $0.continuousClock = clock
    } operation: {
      RepositoriesFeature()
    }
    let location = RemoteRepositoryFixtures.location("/srv/app")

    let load = Task { await feature.loadRepositoriesData([PersistedRepositoryEntry(path: location.id, kind: .git)]) }
    await Task.megaYield()
    await clock.advance(by: RepositoriesFeature.remoteLoadDeadline)
    let (_, failures) = await load.value
    gate.open()

    #expect(failures.map(\.isHostUnreachable) == [true])
  }

  /// A refused login or a changed host key needs the user, so it is not "unreachable".
  @Test func onlyAHostThatDoesNotAnswerIsUnreachable() {
    #expect(isRemoteHostUnreachable(RemoteRepositoryHostError.connection(.unreachable)))
    #expect(isRemoteHostUnreachable(RemoteRepositoryRefreshError.timedOut))
    #expect(!isRemoteHostUnreachable(RemoteRepositoryHostError.connection(.authentication)))
    #expect(!isRemoteHostUnreachable(RemoteRepositoryRefreshError.connection(.hostKey)))
    #expect(!isRemoteHostUnreachable(RemoteRepositoryRefreshError.connection(.exit(1, "bash: not found"))))
    #expect(!isRemoteHostUnreachable(RepositoryHostError.hostProfileMissing(UUID())))
  }

  /// A remote plain folder needs its host to be known, as a remote git repository does.
  @Test(.dependencies) func aRemotePlainFolderWithoutItsHostFailsToLoad() async {
    let location = RemoteRepositoryFixtures.location("/home/dev/notes")
    let feature = withDependencies {
      $0.continuousClock = TestClock()
    } operation: {
      RepositoriesFeature()
    }

    let (loaded, failures) = await feature.loadRepositoriesData([
      PersistedRepositoryEntry(path: location.id, kind: .plain)
    ])

    #expect(loaded.isEmpty)
    #expect(failures.map(\.message) == ["Remote projects are not available yet."])
  }

  // MARK: - Refresh cadence (B3f)

  @Test func theRefreshCadencePollsTheFocusedRepositoryFasterAndBacksOff() {
    #expect(RepositoriesFeature.remoteRefreshDelay(isFocused: true, failures: 0) == .seconds(10))
    #expect(RepositoriesFeature.remoteRefreshDelay(isFocused: false, failures: 0) == .seconds(45))
    #expect(RepositoriesFeature.remoteRefreshDelay(isFocused: true, failures: 1) == .seconds(20))
    #expect(RepositoriesFeature.remoteRefreshDelay(isFocused: false, failures: 2) == .seconds(180))
    #expect(RepositoriesFeature.remoteRefreshDelay(isFocused: false, failures: 3) == .seconds(300))
    // A held connection stays open between background polls only within ControlPersist.
    let controlPersist = Duration.seconds(RemoteConnectionOwner.Configuration().controlPersistSeconds)
    #expect(RepositoriesFeature.remoteRefreshBackgroundInterval < controlPersist)
    #expect(RepositoriesFeature.remoteRefreshDelay(isFocused: true, failures: 40) == .seconds(300))
  }

  /// A loaded remote repository is polled on its host: a renamed branch renames its
  /// worktree, and edited files update its line counts. Leaving the list stops the polls
  /// and releases its connection hold.
  @Test(.dependencies) func aPollAppliesBranchAndLineChangesFromTheHost() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let clock = TestClock()
    let holds = LockIsolated(0)
    let releases = LockIsolated(0)
    var client = fixture.remoteClient
    client.holdConnection = { _ in
      holds.withValue { $0 += 1 }
      return RemoteConnectionHold(release: { releases.withValue { $0 += 1 } })
    }
    let repository = try await fixture.loadedRepository()
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteRepositoryHostClient.self] = client
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.repositoriesLoaded([repository], failures: [], roots: [repository.location], animated: false))
    #expect(store.state.remoteRefreshRepositoryIDs == [repository.id])
    try await fixture.git(["branch", "-m", "trunk", "renamed"])
    try Data("one\ntwo\n".utf8).write(to: fixture.main.appending(path: "a.txt"))

    await clock.advance(by: RepositoriesFeature.remoteRefreshBackgroundInterval)
    await store.receive(\.remoteRepositoryRefreshDue)
    await store.receive(\.remoteRepositoryRefreshed, timeout: .seconds(30))

    #expect(store.state.repositories[id: repository.id]?.worktrees.map(\.name) == ["renamed"])
    #expect(store.state.worktreeInfoByID[repository.id]?.addedLines == 1)
    #expect(store.state.remoteRefreshFingerprints[repository.id]?.isEmpty == false)
    #expect(holds.value == 1)

    await store.send(.repositoriesLoaded([], failures: [], roots: [], animated: false))
    await store.finish(timeout: .seconds(10))
    #expect(store.state.remoteRefreshRepositoryIDs.isEmpty)
    #expect(releases.value == 1)
  }

  /// A failed poll keeps the last state, marks an unreachable host, and waits longer;
  /// the next good poll clears the mark.
  @Test(.dependencies) func aFailedPollKeepsTheLastStateAndBacksOff() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let clock = TestClock()
    let reachable = LockIsolated(false)
    let refused = RemoteCommandOutcome.exited(
      RemoteCommandResult(
        exitCode: 255, output: Data(), outputTruncated: false,
        errorOutput: "ssh: connect to host mini port 22: Connection refused"))
    let lane = GitFixture.localLane
    let flaky = RemoteCommandLane(
      run: { reachable.value ? try await lane.run($0, $1) : refused },
      runScript: { reachable.value ? try await lane.runScript($0, $1) : refused })
    let repository = try await fixture.loadedRepository()
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteRepositoryHostClient.self] = fixture.remoteClient(lane: flaky)
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.repositoriesLoaded([repository], failures: [], roots: [repository.location], animated: false))
    await clock.advance(by: RepositoriesFeature.remoteRefreshBackgroundInterval)
    await store.receive(\.remoteRepositoryRefreshDue)
    await store.receive(\.remoteRepositoryRefreshed, timeout: .seconds(30))

    #expect(store.state.unreachableRepositoryIDs == [repository.id])
    #expect(store.state.repositories[id: repository.id] == repository)
    #expect(store.state.remoteRefreshFailureCounts[repository.id] == 1)

    // The next poll waits twice as long.
    reachable.setValue(true)
    await clock.advance(by: RepositoriesFeature.remoteRefreshBackgroundInterval)
    await Task.megaYield()
    #expect(store.state.remoteRefreshInFlightIDs.isEmpty)
    await clock.advance(by: RepositoriesFeature.remoteRefreshBackgroundInterval)
    await store.receive(\.remoteRepositoryRefreshDue)
    await store.receive(\.remoteRepositoryRefreshed, timeout: .seconds(30))
    #expect(store.state.unreachableRepositoryIDs.isEmpty)
    #expect(store.state.remoteRefreshFailureCounts[repository.id] == nil)

    await store.send(.repositoriesLoaded([], failures: [], roots: [], animated: false))
    await store.finish(timeout: .seconds(10))
  }

  /// A worktree that appears on the host updates the repository as a load would; changed
  /// remote URLs refresh the pull requests.
  @Test(.dependencies) func aPollReloadsForNewWorktreesAndRefreshesPullRequestsForNewRemotes() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let clock = TestClock()
    let repository = try await fixture.loadedRepository()
    @Shared(.repositorySettings(repository.location)) var repositorySettings
    $repositorySettings.withLock { $0.fetchPullRequestState = false }
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteRepositoryHostClient.self] = fixture.remoteClient
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.repositoriesLoaded([repository], failures: [], roots: [repository.location], animated: false))
    await clock.advance(by: RepositoriesFeature.remoteRefreshBackgroundInterval)
    await store.receive(\.remoteRepositoryRefreshed, timeout: .seconds(30))

    try await fixture.git(["remote", "add", "origin", "git@github.com:example/app.git"])
    await clock.advance(by: RepositoriesFeature.remoteRefreshBackgroundInterval)
    await store.receive(\.remoteRepositoryRefreshed, timeout: .seconds(30))
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested, timeout: .seconds(10))

    _ = try await fixture.addWorktree("added", branch: "added")
    await clock.advance(by: RepositoriesFeature.remoteRefreshBackgroundInterval)
    await store.receive(\.remoteRepositoryRefreshed, timeout: .seconds(30))
    await store.receive(\.repositoriesLoaded, timeout: .seconds(10))
    #expect(Set(store.state.repositories[id: repository.id]?.worktrees.map(\.name) ?? []) == ["trunk", "added"])

    await store.send(.repositoriesLoaded([], failures: [], roots: [], animated: false))
    await store.finish(timeout: .seconds(10))
  }

  /// A reload keeps a loaded remote repository as it is: it never asks a host that is
  /// down, and the list never loses the repository. A new remote entry still loads.
  @Test(.dependencies) func aReloadKeepsLoadedRemoteRepositoriesWithoutAskingTheHost() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let repository = try await fixture.loadedRepository()
    let asked = LockIsolated(0)
    let refused = RemoteCommandOutcome.exited(
      RemoteCommandResult(
        exitCode: 255, output: Data(), outputTruncated: false, errorOutput: "Connection refused"))
    let counting = RemoteCommandLane(
      run: { _, _ in
        asked.withValue { $0 += 1 }
        return refused
      },
      runScript: { _, _ in
        asked.withValue { $0 += 1 }
        return refused
      })
    let feature = withDependencies {
      $0[RemoteRepositoryHostClient.self] = fixture.remoteClient(lane: counting)
      $0.continuousClock = TestClock()
    } operation: {
      RepositoriesFeature()
    }
    let other = RemoteRepositoryFixtures.location("/srv/other")
    let entries = [
      PersistedRepositoryEntry(path: repository.id, kind: .git), PersistedRepositoryEntry(path: other.id, kind: .git),
    ]

    let (loaded, failures) = await feature.loadRepositoriesData(entries, knownRemoteRepositories: [repository])

    #expect(loaded == [repository])
    #expect(failures.map(\.rootID) == [other.id])
    #expect(asked.value == 1)
  }

  @Test(.dependencies) func aPollThatReachesTheHostClearsAStaleUnreachableMark() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let clock = TestClock()
    let repository = try await fixture.loadedRepository()
    var state = RepositoriesFeature.State()
    state.pollUnreachableRepositoryIDs = [repository.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteRepositoryHostClient.self] = fixture.remoteClient
      $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.repositoriesLoaded([repository], failures: [], roots: [repository.location], animated: false))

    // The host answers, but the folder is gone: reachable, and still a failure.
    try FileManager.default.removeItem(at: fixture.main)
    await clock.advance(by: RepositoriesFeature.remoteRefreshBackgroundInterval)
    await store.receive(\.remoteRepositoryRefreshed, timeout: .seconds(30))

    #expect(store.state.unreachableRepositoryIDs.isEmpty)
    #expect(store.state.remoteRefreshFailureCounts[repository.id] == 1)
    await store.send(.repositoriesLoaded([], failures: [], roots: [], animated: false))
    await store.finish(timeout: .seconds(10))
  }

  /// A load that fails because the host does not answer keeps its unreachable mark when
  /// the repository leaves the cadence.
  @Test(.dependencies) func aRepositoryThatFailsAsUnreachableKeepsItsMark() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let repository = try await fixture.loadedRepository()
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteRepositoryHostClient.self] = fixture.remoteClient
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.repositoriesLoaded([repository], failures: [], roots: [repository.location], animated: false))

    let failure = RepositoriesFeature.LoadFailure(
      rootID: repository.id, message: "The remote host could not be reached.", isHostUnreachable: true)
    await store.send(.repositoriesLoaded([], failures: [failure], roots: [repository.location], animated: false))

    #expect(store.state.remoteRefreshRepositoryIDs.isEmpty)
    #expect(store.state.unreachableRepositoryIDs == [repository.id])
    await store.finish(timeout: .seconds(10))
  }

  /// Polls pause while the app is inactive and run at once when it is active again; an
  /// unreachable host gets no pull request refresh.
  @Test(.dependencies) func pollsPauseWhileInactiveAndUnreachableHostsGetNoPullRequestRefresh() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let clock = TestClock()
    let repository = try await fixture.loadedRepository()
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteRepositoryHostClient.self] = fixture.remoteClient
      $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.repositoriesLoaded([repository], failures: [], roots: [repository.location], animated: false))

    await store.send(.setRemoteRefreshActive(false))
    await clock.advance(by: .seconds(600))
    await Task.megaYield()
    #expect(store.state.remoteRefreshInFlightIDs.isEmpty)

    await store.send(.setRemoteRefreshActive(true))
    await store.receive(\.remoteRepositoryRefreshDue)
    await store.receive(\.remoteRepositoryRefreshed, timeout: .seconds(30))

    var unreachable = store.state
    unreachable.pollUnreachableRepositoryIDs = [repository.id]
    let gated = TestStore(initialState: unreachable) {
      RepositoriesFeature()
    }
    await gated.send(
      .githubIntegration(
        .repositoryPullRequestRefreshRequested(
          repositoryLocation: repository.location, worktreeIDs: repository.worktrees.map(\.id))))

    await store.send(.repositoriesLoaded([], failures: [], roots: [], animated: false))
    await store.finish(timeout: .seconds(10))
  }

  /// A launch in the background pauses polls before the first load: the loaded repository
  /// gets no poll until the app becomes active.
  @Test(.dependencies) func aRepositoryLoadedWhilePausedWaitsForActivation() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let clock = TestClock()
    let repository = try await fixture.loadedRepository()
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteRepositoryHostClient.self] = fixture.remoteClient
      $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.setRemoteRefreshActive(false))
    await store.send(.repositoriesLoaded([repository], failures: [], roots: [repository.location], animated: false))

    await clock.advance(by: .seconds(600))
    await Task.megaYield()
    #expect(store.state.remoteRefreshInFlightIDs.isEmpty)
    #expect(store.state.remoteRefreshFailureCounts.isEmpty)

    await store.send(.setRemoteRefreshActive(true))
    await store.receive(\.remoteRepositoryRefreshDue)
    await store.receive(\.remoteRepositoryRefreshed, timeout: .seconds(30))

    await store.send(.repositoriesLoaded([], failures: [], roots: [], animated: false))
    await store.finish(timeout: .seconds(10))
  }

  /// A reload that keeps a remote repository does not clear the mark that its poll set,
  /// and the failures it passes on carry only load marks.
  @Test(.dependencies) func aReloadThatKeepsARemoteRepositoryKeepsItsPollMark() async throws {
    let repository = RemoteRepositoryFixtures.gitRepository()
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.isInitialLoadComplete = true
    state.pollUnreachableRepositoryIDs = [repository.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [repository], failures: [], roots: [repository.location], animated: false,
        reusedRemoteRepositoryIDs: [repository.id]))

    #expect(store.state.unreachableRepositoryIDs == [repository.id])
    #expect(store.state.currentLoadFailures.isEmpty)
  }

  /// A load that kept a remote repository brings back the version it captured; a poll may
  /// have changed it since, and that newer version stays.
  @Test(.dependencies) func aKeptRemoteRepositoryKeepsTheVersionThatAPollUpdated() {
    let captured = RemoteRepositoryFixtures.gitRepository()
    let root = captured.location
    let added = RemoteRepositoryFixtures.location("/home/dev/app-added")
    let newer = Repository(
      location: root, name: captured.name, kind: .git,
      worktrees: IdentifiedArray(
        uniqueElements: Array(captured.worktrees)
          + [Worktree(name: "added", detail: "../app-added", location: added, repositoryLocation: root)]))
    var state = RepositoriesFeature.State()
    state.repositories = [newer]
    state.isInitialLoadComplete = true

    let reconciled = state.reconcilingReusedRemoteRepositories([captured], reusedIDs: [captured.id])
    let notKept = state.reconcilingReusedRemoteRepositories([captured], reusedIDs: [])

    #expect(reconciled == [newer])
    #expect(notKept == [captured])
    #expect(state.retainedRemoteRepositories == [newer])
    var beforeLoad = state
    beforeLoad.isInitialLoadComplete = false
    #expect(beforeLoad.retainedRemoteRepositories.isEmpty)
  }

  /// A reload in the reducer keeps a loaded remote repository and never asks its host. Every
  /// load entry point, such as saving a workspace, passes the retained repositories: the
  /// parameter has no default.
  @Test(.dependencies) func aReloadInTheReducerKeepsALoadedRemoteRepository() async {
    let repository = RemoteRepositoryFixtures.gitRepository()
    let asked = LockIsolated(0)
    let hostProfileID = RemoteRepositoryFixtures.hostProfileID
    let counting = RemoteRepositoryHost(
      hostProfileID: hostProfileID,
      lane: RemoteCommandLane(
        run: { _, _ in
          asked.withValue { $0 += 1 }
          return .timedOut
        },
        runScript: { _, _ in
          asked.withValue { $0 += 1 }
          return .timedOut
        }))
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.repositoryRoots = [repository.location]
    state.isInitialLoadComplete = true
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RemoteRepositoryHostClient.self] = RemoteRepositoryHostClient(host: { $0 == hostProfileID ? counting : nil })
      $0.continuousClock = TestClock()
      $0.repositoryPersistence.loadRepositoryEntries = { [PersistedRepositoryEntry(path: repository.id, kind: .git)] }
    }
    store.exhaustivity = .off

    await store.send(.reloadRepositories(animated: true))
    await store.receive(\.repositoriesLoaded, timeout: .seconds(10))

    #expect(store.state.repositories.map(\.id) == [repository.id])
    #expect(asked.value == 0)
    await store.send(.repositoriesLoaded([], failures: [], roots: [], animated: false))
    await store.finish(timeout: .seconds(10))
  }

  // MARK: - Adding a folder (C1)

  /// A path on the host is found as the add flow needs it: a repository adds its main
  /// worktree, from a subfolder or a linked worktree too; any other folder is plain.
  @Test func aFolderOnTheHostIsFoundAsItsRepositoryRootOrAPlainFolder() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let linked = try await fixture.addWorktree("linked", branch: "side")
    let subfolder = fixture.main.appending(path: "sub", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
    let plain = fixture.root.appending(path: "plain", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
    let host = RemoteRepositoryHost(hostProfileID: UUID(), lane: GitFixture.localLane.printingAGreetingFirst())
    let main = fixture.main.path(percentEncoded: false).trimmingSuffix("/")

    for path in [main, subfolder.path(percentEncoded: false), linked.path(percentEncoded: false)] {
      #expect(try await host.discoverFolder(path) == RemoteFolderDiscovery(rootPath: main, kind: .git), "\(path)")
    }
    let plainPath = plain.path(percentEncoded: false).trimmingSuffix("/")
    #expect(try await host.discoverFolder(plainPath) == RemoteFolderDiscovery(rootPath: plainPath, kind: .plain))
    await #expect(throws: RemoteFolderValidationError.folderNotFound(plainPath + "/none")) {
      _ = try await host.discoverFolder(plainPath + "/none")
    }
    let home = try #require(ProcessInfo.processInfo.environment["HOME"])
    let resolvedHome = try #require(realpath(home, nil))
    defer { free(resolvedHome) }
    #expect(try await host.discoverFolder("~").rootPath == String(cString: resolvedHome))
  }

  /// A worktree of a bare repository adds the bare repository, as `wt root` finds it.
  @Test func aWorktreeOfABareRepositoryAddsTheBareRepository() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let bare = try await fixture.makeUpstream()
    let worktree = fixture.root.appending(path: "bare-wt", directoryHint: .isDirectory)
    _ = try await fixture.executable.run(["worktree", "add", "-q", worktree.path, "trunk"], in: bare, shell: .live)
    let host = RemoteRepositoryHost(hostProfileID: UUID(), lane: GitFixture.localLane)
    let barePath = bare.path(percentEncoded: false).trimmingSuffix("/")

    #expect(
      try await host.discoverFolder(worktree.path(percentEncoded: false))
        == RemoteFolderDiscovery(rootPath: barePath, kind: .git))
    #expect(try await host.discoverFolder(barePath) == RemoteFolderDiscovery(rootPath: barePath, kind: .git))
  }

  /// A git error other than "not a repository" is reported, and an empty root is refused.
  @Test func aGitErrorIsReportedAndAnEmptyRootIsRefused() async {
    func host(replying reply: String) -> RemoteRepositoryHost {
      let outcome = RemoteCommandOutcome.exited(
        RemoteCommandResult(exitCode: 0, output: Data(reply.utf8), outputTruncated: false, errorOutput: ""))
      return RemoteRepositoryHost(
        hostProfileID: UUID(), lane: RemoteCommandLane(run: { _, _ in outcome }, runScript: { _, _ in outcome }))
    }

    await #expect(throws: RemoteRepositoryRefreshError.gitFailed("fatal: detected dubious ownership")) {
      _ = try await host(replying: "PROWL_FOLDER\tgit-error\tfatal: detected dubious ownership\n").discoverFolder(
        "/srv/app")
    }
    await #expect(throws: RemoteFolderValidationError.invalidPath) {
      _ = try await host(replying: "PROWL_FOLDER\tgit\t\n").discoverFolder("/srv/app")
    }
    await #expect(throws: RemoteFolderValidationError.folderInaccessible("/srv/app")) {
      _ = try await host(replying: "PROWL_FOLDER\tinaccessible\n").discoverFolder("/srv/app")
    }
  }

  // MARK: - Browsing folders

  /// The folder browser lists the subfolders of a host folder: repositories (a bare one
  /// too) are marked, a folder that cannot be opened is listed as such, files are left
  /// out, a link to a folder is a folder, and a name with a tab is kept whole.
  @Test func aHostFolderListsItsSubfoldersSorted() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    let bare = try await fixture.makeUpstream()
    let manager = FileManager.default
    for name in ["plain", "Zeta", "日本語", ".hidden", "tab\tname", "line\nbreak", "locked"] {
      try manager.createDirectory(at: fixture.root.appending(path: name), withIntermediateDirectories: false)
    }
    try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.root.appending(path: "locked").path)
    defer {
      try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.appending(path: "locked").path)
    }
    try manager.createSymbolicLink(at: fixture.root.appending(path: "link"), withDestinationURL: fixture.main)
    try Data().write(to: fixture.root.appending(path: "file.txt"))
    let host = RemoteRepositoryHost(hostProfileID: UUID(), lane: GitFixture.localLane.printingAGreetingFirst())
    let rootPath = fixture.root.path(percentEncoded: false).trimmingSuffix("/")

    let listing = try await host.listFolder(rootPath)

    #expect(listing.path == rootPath)
    #expect(
      listing.entries == [
        RemoteFolderListing.Entry(name: ".hidden", isRepository: false, isAccessible: true),
        RemoteFolderListing.Entry(name: "link", isRepository: true, isAccessible: true),
        RemoteFolderListing.Entry(name: "locked", isRepository: false, isAccessible: false),
        RemoteFolderListing.Entry(name: "main", isRepository: true, isAccessible: true),
        RemoteFolderListing.Entry(name: "plain", isRepository: false, isAccessible: true),
        RemoteFolderListing.Entry(name: "tab\tname", isRepository: false, isAccessible: true),
        RemoteFolderListing.Entry(
          name: bare.lastPathComponent, isRepository: true, isAccessible: true),
        RemoteFolderListing.Entry(name: "Zeta", isRepository: false, isAccessible: true),
        RemoteFolderListing.Entry(name: "日本語", isRepository: false, isAccessible: true),
      ])
    #expect(listing.omittedCount == 0)
    let home = try #require(ProcessInfo.processInfo.environment["HOME"])
    let resolvedHome = try #require(realpath(home, nil))
    defer { free(resolvedHome) }
    #expect(listing.home == String(cString: resolvedHome))
  }

  /// `~` starts at the host's home; a missing path and a file are reported; a large
  /// folder lists the first entries and counts the rest.
  @Test func browsingResolvesTheHomeAndReportsWhatCannotBeListed() async throws {
    let fixture = try await GitFixture()
    defer { fixture.remove() }
    for index in 1...5 {
      try FileManager.default.createDirectory(
        at: fixture.root.appending(path: "folder\(index)"), withIntermediateDirectories: false)
    }
    let host = RemoteRepositoryHost(hostProfileID: UUID(), lane: GitFixture.localLane)
    let rootPath = fixture.root.path(percentEncoded: false).trimmingSuffix("/")

    let home = try await host.listFolder("~")
    #expect(home.path == home.home)
    let limited = try await host.listFolder(rootPath, limit: 3)
    #expect(limited.entries.map(\.name) == ["folder1", "folder2", "folder3"])
    #expect(limited.omittedCount == 3)
    await #expect(throws: RemoteFolderValidationError.folderNotFound(rootPath + "/none")) {
      _ = try await host.listFolder(rootPath + "/none")
    }
    let file = fixture.main.appending(path: "a.txt").path(percentEncoded: false)
    await #expect(throws: RemoteFolderValidationError.notAFolder(file)) {
      _ = try await host.listFolder(file)
    }
  }

  /// A name that is not UTF-8 cannot be sent back to the host as typed, so it is left out
  /// and the other names keep their text; output without the folder line is incomplete.
  @Test func aNameThatIsNotUTF8IsLeftOutOfTheListing() async throws {
    func host(replying reply: Data) -> RemoteRepositoryHost {
      let outcome = RemoteCommandOutcome.exited(
        RemoteCommandResult(exitCode: 0, output: reply, outputTruncated: false, errorOutput: ""))
      return RemoteRepositoryHost(
        hostProfileID: UUID(), lane: RemoteCommandLane(run: { _, _ in outcome }, runScript: { _, _ in outcome }))
    }
    var reply = Data("PROWL_ENTRY\t\tbefore-the-folder-line\n".utf8)
    reply += Data("PROWL_LIST\tfolder\t/srv\n".utf8)
    reply += Data("PROWL_HOME\t/home/dev\n".utf8)
    reply += Data("PROWL_ENTRY\tg\tアプリ\n".utf8)
    reply += Data("PROWL_ENTRY\t\tbad-".utf8) + Data([0xFF, 0xFE]) + Data("\n".utf8)
    reply += Data("PROWL_ENTRY\tx\tsecret\n".utf8)
    reply += Data("PROWL_MORE\t12\n".utf8)

    let listing = try await host(replying: reply).listFolder("/srv")

    #expect(
      listing
        == RemoteFolderListing(
          path: "/srv", home: "/home/dev",
          entries: [
            RemoteFolderListing.Entry(name: "secret", isRepository: false, isAccessible: false),
            RemoteFolderListing.Entry(name: "アプリ", isRepository: true, isAccessible: true),
          ],
          omittedCount: 12))
    await #expect(throws: RemoteRepositoryRefreshError.incompleteOutput) {
      _ = try await host(replying: Data("PROWL_ENTRY\t\tapp\n".utf8)).listFolder("/srv")
    }
    await #expect(throws: RemoteFolderValidationError.folderInaccessible("/srv")) {
      _ = try await host(replying: Data("PROWL_LIST\tinaccessible\n".utf8)).listFolder("/srv")
    }
  }

  // MARK: - A real host (opt-in)

  /// Runs against a real SSH host when `PROWL_REMOTE_LANE_HOST` names one, such as
  /// `TEST_RUNNER_PROWL_REMOTE_LANE_HOST=mini xcodebuild test …`. Skipped otherwise.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PROWL_REMOTE_LANE_HOST"] != nil))
  func aRealHostListsAndChangesWorktrees() async throws {
    let hostName = try #require(ProcessInfo.processInfo.environment["PROWL_REMOTE_LANE_HOST"])
    let owner = RemoteConnectionOwner(
      connection: ConnectionKey(user: NSUserName(), hostname: hostName),
      recipe: SSHConnectionRecipe(destination: hostName),
      configuration: RemoteConnectionOwner.Configuration(controlDirectory: "/tmp/prowl-lane-live"))
    let lane = RemoteCommandLane.owner(owner)
    let root = "/tmp/prowl-b3b-live-\(UUID().uuidString)"
    let setup = """
      set -e
      git init -q -b trunk "$1/app"
      cd "$1/app"
      echo one > a.txt
      git add a.txt
      git -c user.name=Test -c user.email=t@example.com -c commit.gpgSign=false commit -qm Initial
      git remote add origin git@github.com:example/app.git
      git worktree add -q -b side "$1/app-side"
      cd "$1" && pwd -P
      """
    guard
      case .exited(let created) = try await lane.run(
        RemoteShellCommand(executable: "sh", arguments: ["-c", setup, "sh", root]), .commandLane),
      created.exitCode == 0
    else {
      Issue.record("The fixture repository was not created")
      return
    }
    let physicalRoot = (String(bytes: created.output, encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
    let hostProfileID = UUID()
    let location = RepositoryLocation.remote(hostProfileID: hostProfileID, path: physicalRoot + "/app")
    let remote = RemoteRepositoryHost(hostProfileID: hostProfileID, lane: lane)
    let host = RepositoryHost(
      local: .testValue, remote: RemoteRepositoryHostClient(host: { $0 == hostProfileID ? remote : nil }))

    // The add flow (C1a) finds the main worktree from a linked one, and the fixture's
    // parent as a plain folder.
    let main = RemoteFolderDiscovery(rootPath: physicalRoot + "/app", kind: .git)
    #expect(try await remote.discoverFolder(physicalRoot + "/app-side") == main)
    #expect(
      try await remote.discoverFolder(physicalRoot) == RemoteFolderDiscovery(rootPath: physicalRoot, kind: .plain))
    await #expect(throws: RemoteFolderValidationError.folderNotFound(physicalRoot + "/none")) {
      _ = try await remote.discoverFolder(physicalRoot + "/none")
    }
    #expect(try await remote.discoverFolder("~").rootPath.hasPrefix("/"))

    let worktrees = try await host.worktrees(in: location)
    #expect(Set(worktrees.map(\.name)) == ["trunk", "side"])
    #expect(try await host.branchRefs(in: location) == ["side", "trunk"])
    #expect(await host.isValidBranchName("feature/next", in: location))
    #expect(try await host.remoteNames(in: location) == ["origin"])
    #expect(await host.remoteInfo(for: location)?.owner == "example")
    var madeByWt: Worktree?
    let request = GitWorktreeCreateRequest(
      name: "made-by-wt", repoRoot: URL(filePath: location.path),
      baseDirectory: URL(filePath: physicalRoot + "/worktrees", directoryHint: .isDirectory),
      copyFiles: .init(ignored: false, untracked: false), baseRef: "trunk")
    for try await event in host.createWorktreeStream(in: location, request) {
      if case .finished(let worktree) = event { madeByWt = worktree }
    }
    let made = try #require(madeByWt)
    #expect(made.location.path == physicalRoot + "/worktrees/made-by-wt")
    #expect(try await host.worktrees(in: location).contains { $0.id == made.id })
    try await host.removeWorktree(made, deleteBranch: true)
    #expect(try await host.remoteHomeDirectory(in: location)?.hasPrefix("/") == true)

    let side = try #require(worktrees.first { !$0.isMain })
    try await host.renameBranch(in: side.location, to: "renamed")
    let renamed = try #require(try await host.worktrees(in: location).first { !$0.isMain })
    #expect(renamed.name == "renamed")
    try await host.removeWorktree(renamed, deleteBranch: true)
    #expect(try await host.worktrees(in: location).map(\.name) == ["trunk"])
    #expect(try await host.localBranchNames(in: location) == ["trunk"])

    _ = try await lane.run(RemoteShellCommand(executable: "rm", arguments: ["-rf", root]), .commandLane)
    await owner.shutdown()
  }
}

/// A repository in a temporary folder, reached as a remote folder through a lane that
/// runs on this Mac.
private struct GitFixture {
  let root: URL
  let main: URL
  let executable: GitExecutable

  var remoteLocation: RepositoryLocation {
    RemoteRepositoryFixtures.location(main.path(percentEncoded: false).trimmingSuffix("/"))
  }

  var remoteClient: RemoteRepositoryHostClient { remoteClient(lane: Self.localLane) }

  func remoteClient(lane: RemoteCommandLane) -> RemoteRepositoryHostClient {
    let hostProfileID = RemoteRepositoryFixtures.hostProfileID
    let host = RemoteRepositoryHost(hostProfileID: hostProfileID, lane: lane)
    return RemoteRepositoryHostClient(host: { id in id == hostProfileID ? host : nil })
  }

  /// `sh -s` and `bash -s` with this process's `PATH`, as the owner's lane runs them with
  /// the login `PATH`.
  static let localLane = lane(bash: "/bin/bash")

  /// Scripts run with `bash`, so a test can pick bash 3.2 or bash 5. `pathPrefix` comes
  /// before the process's `PATH` for scripts, such as a folder with a `git` wrapper.
  static func lane(bash: String, pathPrefix: String? = nil) -> RemoteCommandLane {
    let searchPath = [pathPrefix, ProcessInfo.processInfo.environment["PATH"]].compactMap { $0 }.joined(separator: ":")
    return RemoteCommandLane(
      run: { command, limits in
        var command = command
        command.environment.insert((name: "PATH", value: searchPath), at: 0)
        return await RemoteCommandRunner.live.execute(
          URL(fileURLWithPath: "/bin/sh"), ["-s"], Data(try command.script().utf8), limits, nil)
      },
      runScript: { script, limits in
        let input = try script.standardInput(path: searchPath)
        return await RemoteCommandRunner.live.execute(
          URL(fileURLWithPath: bash), ["-s"], Data(input.utf8), limits, nil)
      },
      stream: { script, limits, onLine in
        let input = try script.standardInput(path: searchPath)
        let output = RemoteOutputLineSplitter { onLine(.standardOutput, $0) }
        let errorOutput = RemoteOutputLineSplitter { onLine(.standardError, $0) }
        let outcome = await RemoteCommandRunner.live.executeStreaming(
          URL(fileURLWithPath: bash), ["-s"], Data(input.utf8), limits, nil
        ) { stream, chunk in
          switch stream {
          case .standardOutput: output.append(chunk)
          case .standardError: errorOutput.append(chunk)
          }
        }
        output.finish()
        errorOutput.finish()
        return outcome
      })
  }

  init() async throws {
    // `realpath`, so the stored path is the one git lists for the main worktree.
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let pointer = realpath(temporary.path, nil)
    let resolved = try #require(pointer)
    defer { free(resolved) }
    root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    main = root.appending(path: "main", directoryHint: .isDirectory)
    executable = try await GitExecutableResolver.shared.resolve()
    _ = try await executable.run(["init", "-q", "-b", "trunk", main.path], shell: .live)
    try Data("one\n".utf8).write(to: main.appending(path: "a.txt"))
    try await git(["add", "a.txt"])
    try await commit()
  }

  func git(_ arguments: [String], in directory: URL? = nil) async throws {
    _ = try await executable.run(arguments, in: directory ?? main, shell: .live)
  }

  func commit() async throws {
    try await git([
      "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgSign=false",
      "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Initial",
    ])
  }

  func addWorktree(_ name: String, branch: String) async throws -> URL {
    let url = root.appending(path: name, directoryHint: .isDirectory)
    try await git(["worktree", "add", "-q", "-b", branch, url.path])
    return url
  }

  /// A bare clone of the repository, to fetch from.
  func makeUpstream() async throws -> URL {
    let url = root.appending(path: "upstream.git", directoryHint: .isDirectory)
    _ = try await executable.run(["clone", "-q", "--bare", main.path, url.path], shell: .live)
    return url
  }

  /// A folder with a `git` that runs `prelude` before the real git, for scripts that the
  /// lane runs. `PROWL_REAL_GIT` and `PROWL_TEST_ROOT` are set for the prelude.
  func gitWrapper(_ prelude: String) throws -> String {
    let folder = root.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      PROWL_REAL_GIT='\(executable.url.path(percentEncoded: false))'
      PROWL_TEST_ROOT='\(root.path(percentEncoded: false).trimmingSuffix("/"))'
      \(prelude)
      exec "$PROWL_REAL_GIT" "$@"

      """
    let url = folder.appending(path: "git")
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return folder.path(percentEncoded: false)
  }

  struct CreationResult {
    let failed: Bool
    let host: RepositoryHost
  }

  /// Runs the reducer's creation of `branch` under `<root>/worktrees`, with `wrapper`'s
  /// `git` for the creation script, and waits for its cleanup.
  @MainActor
  func createThroughTheReducer(
    branch: String, copyUntracked: Bool = false, wrapper: String? = nil, lane: RemoteCommandLane? = nil
  ) async throws -> CreationResult {
    let location = remoteLocation
    let plainHost = RepositoryHost(local: .testValue, remote: remoteClient)
    let wrappedClient = remoteClient(lane: lane ?? Self.lane(bash: "/bin/bash", pathPrefix: wrapper))
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = false
      $0.global.copyUntrackedOnWorktreeCreate = copyUntracked
      $0.global.copyIgnoredOnWorktreeCreate = false
    }
    @Shared(.repositorySettings(location)) var repositorySettings
    $repositorySettings.withLock { $0.worktreeBaseDirectoryPath = "../worktrees" }
    var state = RepositoriesFeature.State()
    state.repositories = [
      Repository(
        location: location, name: "main",
        worktrees: IdentifiedArray(uniqueElements: try await plainHost.worktrees(in: location)))
    ]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0[RemoteRepositoryHostClient.self] = wrappedClient
    }
    store.exhaustivity = .off
    await store.send(
      .worktreeCreation(
        .createWorktreeInRepository(
          repositoryID: location.id, nameSource: .explicit(branch), baseRefSource: .explicit("trunk"),
          fetchRemote: false)))
    await store.receive(\.worktreeCreation.createRandomWorktreeFailed, timeout: .seconds(60))
    await store.finish(timeout: .seconds(60))
    return CreationResult(failed: store.state.alert != nil, host: plainHost)
  }

  /// The repository as the load gives it, listed through the local lane.
  func loadedRepository() async throws -> Repository {
    let host = RepositoryHost(local: .testValue, remote: remoteClient)
    return Repository(
      location: remoteLocation, name: "main", kind: .git,
      worktrees: IdentifiedArray(uniqueElements: try await host.worktrees(in: remoteLocation)))
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

extension RemoteCommandLane {
  /// The lane, except that each stream ends as a dropped connection after its script ran.
  fileprivate func droppingTheConnectionAfterEachStream() -> Self {
    let lane = self
    return RemoteCommandLane(
      run: { try await lane.run($0, $1) },
      runScript: { try await lane.runScript($0, $1) },
      stream: { script, limits, onLine in
        _ = try await lane.stream(script, limits, onLine)
        return .exited(
          RemoteCommandResult(
            exitCode: 255, output: Data(), outputTruncated: false, errorOutput: "Connection closed by remote host"))
      })
  }

  /// The lane, with a greeting printed before every command and script, as a `.zshenv`
  /// that prints does.
  fileprivate func printingAGreetingFirst() -> Self {
    let lane = self
    return RemoteCommandLane(
      run: { command, limits in greeted(try await lane.run(command, limits)) },
      runScript: { script, limits in greeted(try await lane.runScript(script, limits)) },
      stream: { script, limits, onLine in
        onLine(.standardOutput, "Welcome to the build server!")
        return try await lane.stream(script, limits, onLine)
      })
  }

  /// The lane, except that a command that `fails` matches ends as a dropped connection.
  fileprivate func failing(_ fails: @escaping @Sendable (RemoteShellCommand) -> Bool) -> Self {
    let dropped = RemoteCommandOutcome.exited(
      RemoteCommandResult(
        exitCode: 255, output: Data(), outputTruncated: false, errorOutput: "Connection closed by remote host"))
    let lane = self
    return RemoteCommandLane(
      run: { command, limits in fails(command) ? dropped : try await lane.run(command, limits) },
      runScript: { script, limits in try await lane.runScript(script, limits) },
      stream: { script, limits, onLine in try await lane.stream(script, limits, onLine) })
  }
}

extension String {
  fileprivate func trimmingSuffix(_ suffix: String) -> String {
    hasSuffix(suffix) && count > 1 ? String(dropLast(suffix.count)) : self
  }
}

private nonisolated func greeted(_ outcome: RemoteCommandOutcome) -> RemoteCommandOutcome {
  guard case .exited(let result) = outcome else { return outcome }
  return .exited(
    RemoteCommandResult(
      exitCode: result.exitCode, output: Data("Welcome to the build server!\n".utf8) + result.output,
      outputTruncated: result.outputTruncated, errorOutput: result.errorOutput))
}

/// Suspends callers until `open`, whether or not their task is cancelled.
private nonisolated final class CancellationIgnoringGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { continuation in
      let resumeNow = lock.withLock {
        if isOpen { return true }
        waiters.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func open() {
    let waiting = lock.withLock {
      isOpen = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in waiting { waiter.resume() }
  }
}
