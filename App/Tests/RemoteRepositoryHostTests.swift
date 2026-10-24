import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
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

    let worktrees = try await host.worktrees(in: location)
    #expect(Set(worktrees.map(\.name)) == ["trunk", "side"])
    #expect(try await host.branchRefs(in: location) == ["side", "trunk"])
    #expect(await host.isValidBranchName("feature/next", in: location))
    #expect(try await host.remoteNames(in: location) == ["origin"])
    #expect(await host.remoteInfo(for: location)?.owner == "example")
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
  static let localLane = RemoteCommandLane(
    run: { command, limits in
      var command = command
      command.environment.insert((name: "PATH", value: ProcessInfo.processInfo.environment["PATH"] ?? ""), at: 0)
      return await RemoteCommandRunner.live.execute(
        URL(fileURLWithPath: "/bin/sh"), ["-s"], Data(try command.script().utf8), limits, nil)
    },
    runScript: { script, limits in
      let input = try script.standardInput(path: ProcessInfo.processInfo.environment["PATH"])
      return await RemoteCommandRunner.live.execute(
        URL(fileURLWithPath: "/bin/bash"), ["-s"], Data(input.utf8), limits, nil)
    })

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

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

extension RemoteCommandLane {
  /// The lane, with a greeting printed before every command and script, as a `.zshenv`
  /// that prints does.
  fileprivate func printingAGreetingFirst() -> Self {
    let lane = self
    return RemoteCommandLane(
      run: { command, limits in greeted(try await lane.run(command, limits)) },
      runScript: { script, limits in greeted(try await lane.runScript(script, limits)) })
  }

  /// The lane, except that a command that `fails` matches ends as a dropped connection.
  fileprivate func failing(_ fails: @escaping @Sendable (RemoteShellCommand) -> Bool) -> Self {
    let dropped = RemoteCommandOutcome.exited(
      RemoteCommandResult(
        exitCode: 255, output: Data(), outputTruncated: false, errorOutput: "Connection closed by remote host"))
    let lane = self
    return RemoteCommandLane(
      run: { command, limits in fails(command) ? dropped : try await lane.run(command, limits) },
      runScript: { script, limits in try await lane.runScript(script, limits) })
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
