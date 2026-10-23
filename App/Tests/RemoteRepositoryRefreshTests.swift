import Foundation
import Testing

@testable import Prowl

/// The batched refresh of a remote repository (docs-ai 084 B3, D4), against replies
/// recorded on a real host (`Fixtures/RemoteRepositoryRefresh/README.md`) and a local run of
/// the script with `/bin/bash`.
struct RemoteRepositoryRefreshTests {
  private static let repository = RemoteRepositoryFixtures.location("/tmp/prowl-b3-fx/link/app")
  private static let physicalRoot = "/private/tmp/prowl-b3-fx/app"

  // MARK: - Recorded replies

  @Test func aRecordedReplyParsesEveryWorktreeRecord() throws {
    let refresh = try RemoteRepositoryRefresh.parse(Self.fixture("macos-worktrees"))

    #expect(refresh.physicalRootPath == Self.physicalRoot)
    #expect(refresh.isBare == false)
    #expect(refresh.remotesFingerprint == "4202737975-105")
    #expect(
      refresh.worktrees.map(\.path) == [
        Self.physicalRoot, "/private/tmp/prowl-b3-fx/app feature", "/private/tmp/prowl-b3-fx/app-detached",
        "/private/tmp/prowl-b3-fx/app-gone",
      ])
    #expect(refresh.worktrees.map(\.state) == [.present, .present, .present, .missing])
    #expect(refresh.worktrees.map(\.branch) == ["main", "feature/login", nil, "gone"])
    #expect(refresh.worktrees.allSatisfy { $0.head == "268f55b3c566667a410ef0a3c72cc4746ec6e123" })
    #expect(
      refresh.worktrees.map(\.createdAt) == [
        Date(timeIntervalSince1970: 1_792_715_925), Date(timeIntervalSince1970: 1_792_715_926),
        Date(timeIntervalSince1970: 1_792_715_926), nil,
      ])
    // The binary file counts no lines; untracked files are counted, not their lines.
    #expect(
      refresh.worktrees.map(\.lineChanges) == [
        GitLineChanges(added: 2, removed: 1, skippedUntrackedFileCount: 2),
        GitLineChanges(added: 1, removed: 0), GitLineChanges(added: 0, removed: 0), nil,
      ])
  }

  @Test func worktreesAreBuiltAndSortedAsTheLocalHostBuildsThem() throws {
    let refresh = try RemoteRepositoryRefresh.parse(Self.fixture("macos-worktrees"))
    let worktrees = refresh.worktrees(in: Self.repository)

    // Newest first, then git's order; a worktree without a creation time comes last.
    #expect(worktrees.map(\.name) == ["feature/login", "app-detached", "main", "gone"])
    #expect(worktrees.map(\.detail) == ["../app feature", "../app-detached", ".", "../app-gone"])
    #expect(worktrees.map(\.isMain) == [false, false, true, false])
    // Git lists the main worktree by its physical path; it takes the stored location.
    #expect(worktrees[2].location == Self.repository)
    #expect(worktrees[0].location == RemoteRepositoryFixtures.location("/private/tmp/prowl-b3-fx/app feature"))
    #expect(worktrees.allSatisfy { $0.repositoryLocation == Self.repository })
  }

  @Test func lineChangesAreKeyedByWorktreeIDAndLeaveOutMissingFolders() throws {
    let refresh = try RemoteRepositoryRefresh.parse(Self.fixture("macos-worktrees"))
    let changes = refresh.lineChanges(in: Self.repository)

    #expect(changes.count == 3)
    #expect(changes[Self.repository.id] == GitLineChanges(added: 2, removed: 1, skippedUntrackedFileCount: 2))
    #expect(changes[RemoteRepositoryFixtures.location("/private/tmp/prowl-b3-fx/app-gone").id] == nil)
  }

  /// GNU coreutils: the creation time comes from `stat -c %W`.
  @Test func aReplyRecordedOnLinuxParsesTheSameWay() throws {
    let refresh = try RemoteRepositoryRefresh.parse(Self.fixture("linux-worktrees"))
    let worktrees = refresh.worktrees(in: Self.repository)

    #expect(refresh.physicalRootPath == "/tmp/prowl-b3-fx/app")
    #expect(refresh.worktrees.map(\.state) == [.present, .present, .present, .missing])
    #expect(refresh.worktrees.prefix(3).allSatisfy { $0.createdAt == Date(timeIntervalSince1970: 1_792_715_927) })
    #expect(refresh.worktrees.first?.lineChanges == GitLineChanges(added: 2, removed: 1, skippedUntrackedFileCount: 2))
    #expect(worktrees.map(\.name) == ["main", "feature/login", "app-detached", "gone"])
    #expect(worktrees.first?.location == Self.repository)
  }

  @Test func aBareRepositoryHasNoWorktrees() throws {
    let refresh = try RemoteRepositoryRefresh.parse(Self.fixture("macos-bare"))
    let bare = RemoteRepositoryFixtures.location("/tmp/prowl-b3-fx/bare.git")

    #expect(refresh.isBare)
    #expect(refresh.worktrees.map(\.state) == [.bare])
    #expect(refresh.worktrees(in: bare).isEmpty)
  }

  @Test func aFolderThatIsMissingOrNotARepositoryIsReported() throws {
    #expect(throws: RemoteRepositoryRefreshError.missingFolder) {
      try RemoteRepositoryRefresh.parse(Self.fixture("macos-missing"))
    }
    #expect(throws: RemoteRepositoryRefreshError.notGitRepository) {
      try RemoteRepositoryRefresh.parse(Self.fixture("macos-not-git"))
    }
  }

  // MARK: - Reply format

  @Test func outputFromAStartupFileBeforeTheHeaderIsSkipped() throws {
    let reply = "Welcome to the host\n" + (try Self.fixture("macos-worktrees"))

    #expect(try RemoteRepositoryRefresh.parse(reply).worktrees.count == 4)
  }

  @Test func aReplyWithoutItsHeaderOrEndIsIncomplete() throws {
    let reply = try Self.fixture("macos-worktrees")

    #expect(throws: RemoteRepositoryRefreshError.incompleteOutput) {
      try RemoteRepositoryRefresh.parse(reply.replacing("END\n", with: ""))
    }
    #expect(throws: RemoteRepositoryRefreshError.incompleteOutput) {
      try RemoteRepositoryRefresh.parse(reply.replacing("PROWL_REFRESH\t1", with: "PROWL_REFRESH\t2"))
    }
    #expect(throws: RemoteRepositoryRefreshError.incompleteOutput) {
      try RemoteRepositoryRefresh.parse("PROWL_REFRESH\t1\nEND\n")
    }
  }

  @Test func pathsWithATabAndUnknownRecordsParse() throws {
    let reply = """
      PROWL_REFRESH\t1
      ROOT\t/srv/my\tapp
      LATER\tsomething a later format adds
      WORKTREE\tok\tabc\tmain\t\t3\t4\t0\t/srv/my\tapp
      WORKTREE\tok\tabc\twip\t\t\t\t1\t/srv/my\tapp-wip
      END

      """
    let refresh = try RemoteRepositoryRefresh.parse(reply)

    #expect(refresh.physicalRootPath == "/srv/my\tapp")
    #expect(refresh.worktrees.map(\.path) == ["/srv/my\tapp", "/srv/my\tapp-wip"])
    #expect(refresh.worktrees.map(\.createdAt) == [nil, nil])
    // Empty counts: git could not diff the worktree.
    #expect(refresh.worktrees.map(\.lineChanges) == [GitLineChanges(added: 3, removed: 4), nil])
  }

  @Test func aLineThatIsNotUTF8IsReadAsLatin1AndTheOtherLinesStayUTF8() throws {
    var reply = Data("PROWL_REFRESH\t1\nROOT\t/srv/项目\nWORKTREE\tok\t\tmain\t\t0\t0\t0\t/srv/项目\n".utf8)
    reply.append(Data("WORKTREE\tok\t\tlatin\t\t0\t0\t0\t/srv/caf".utf8) + Data([0xE9]) + Data("\nEND\n".utf8))
    let refresh = try RemoteRepositoryRefresh.parse(reply)

    #expect(refresh.physicalRootPath == "/srv/项目")
    #expect(refresh.worktrees.map(\.path) == ["/srv/项目", "/srv/café"])
  }

  /// Git lists the main worktree first; a stored path that is not its root (a subfolder, or
  /// a linked worktree) would otherwise give the wrong worktree the repository's location.
  @Test func aReplyWhoseMainWorktreeIsNotTheRootIsRefused() {
    let reply = """
      PROWL_REFRESH\t1
      ROOT\t/srv/app/sub
      WORKTREE\tok\tabc\tmain\t\t0\t0\t0\t/srv/app
      END

      """

    #expect(throws: RemoteRepositoryRefreshError.notRepositoryRoot) { try RemoteRepositoryRefresh.parse(reply) }
  }

  @Test func everyReportedErrorHasItsOwnCase() {
    let cases: [(String, RemoteRepositoryRefreshError)] = [
      ("missing", .missingFolder), ("inaccessible", .inaccessibleFolder), ("not-git", .notGitRepository),
      ("no-git", .gitMissing),
      ("git\tfatal: detected dubious ownership", .gitFailed("fatal: detected dubious ownership")),
    ]
    for (code, expected) in cases {
      #expect(throws: expected) { try RemoteRepositoryRefresh.parse("PROWL_REFRESH\t1\nERROR\t\(code)\nEND\n") }
    }
  }

  @Test func commandFailuresMapToRefreshErrors() {
    let refused = RemoteCommandResult(
      exitCode: 255, output: Data(), outputTruncated: false,
      errorOutput: "ssh: connect to host mini port 22: Connection refused")
    let truncated = RemoteCommandResult(
      exitCode: 0, output: Data("PROWL_REFRESH\t1\n".utf8), outputTruncated: true, errorOutput: "")

    #expect(throws: RemoteRepositoryRefreshError.connection(.unreachable)) {
      try RemoteRepositoryRefresh.parse(.exited(refused))
    }
    #expect(throws: RemoteRepositoryRefreshError.timedOut) { try RemoteRepositoryRefresh.parse(.timedOut) }
    #expect(throws: RemoteRepositoryRefreshError.connection(.launch("no ssh"))) {
      try RemoteRepositoryRefresh.parse(.launchFailed("no ssh"))
    }
    #expect(throws: RemoteRepositoryRefreshError.incompleteOutput) {
      try RemoteRepositoryRefresh.parse(.exited(truncated))
    }
  }

  @Test func aLocalLocationHasNoRemoteWorktrees() throws {
    let refresh = try RemoteRepositoryRefresh.parse(Self.fixture("macos-worktrees"))

    #expect(refresh.worktrees(in: .local(URL(fileURLWithPath: Self.physicalRoot))).isEmpty)
  }

  // MARK: - The script itself

  /// Runs the script as the command lane sends it (`bash -s`, arguments with `set --`),
  /// with this Mac's `/bin/bash` 3.2 and git, so a change to the script text is checked.
  @Test func theScriptRunsWithBash32AgainstARealRepository() async throws {
    let fixture = try await LocalRepositoryFixture()
    defer { fixture.remove() }
    try await fixture.addLinkedWorktree("linked wt", branch: "side")
    try Data("one\nTWO\nthree\n".utf8).write(to: fixture.main.appending(path: "a.txt"))
    try Data("new\n".utf8).write(to: fixture.main.appending(path: "untracked.txt"))

    let refresh = try RemoteRepositoryRefresh.parse(await Self.runScript(fixture.main.path))

    #expect(refresh.physicalRootPath == (try Self.realpath(fixture.main)))
    #expect(refresh.worktrees.map(\.branch) == ["trunk", "side"])
    #expect(refresh.worktrees.map(\.path).last?.hasSuffix("/linked wt") == true)
    #expect(refresh.worktrees.first?.lineChanges == GitLineChanges(added: 2, removed: 1, skippedUntrackedFileCount: 1))
    #expect(refresh.worktrees.allSatisfy { $0.createdAt != nil })
    #expect(refresh.remotesFingerprint.isEmpty == false)
  }

  @Test func theScriptReportsFoldersItCannotRefresh() async throws {
    let fixture = try await LocalRepositoryFixture()
    defer { fixture.remove() }
    let file = fixture.root.appending(path: "file")
    try Data().write(to: file)
    let locked = fixture.root.appending(path: "locked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let plain = fixture.root.appending(path: "plain", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
    let subfolder = fixture.main.appending(path: "sub", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
    let linked = try await fixture.addLinkedWorktree("linked", branch: "side")

    let expectations: [RefreshExpectation] = [
      RefreshExpectation(path: fixture.root.appending(path: "none").path, searchPath: nil, error: .missingFolder),
      RefreshExpectation(path: file.path, searchPath: nil, error: .inaccessibleFolder),
      RefreshExpectation(path: locked.path, searchPath: nil, error: .inaccessibleFolder),
      RefreshExpectation(path: plain.path, searchPath: nil, error: .notGitRepository),
      RefreshExpectation(path: fixture.main.path, searchPath: "/nonexistent", error: .gitMissing),
      RefreshExpectation(path: subfolder.path, searchPath: nil, error: .notRepositoryRoot),
      RefreshExpectation(path: linked.path, searchPath: nil, error: .notRepositoryRoot),
    ]
    for expectation in expectations {
      let outcome = await Self.runScript(expectation.path, searchPath: expectation.searchPath)
      #expect(throws: expectation.error, "\(expectation.path)") { try RemoteRepositoryRefresh.parse(outcome) }
    }
  }

  /// `test -e` fails for a path below a folder that cannot be searched, although the path
  /// still exists; that must not read as a deleted repository.
  @Test func aRepositoryBelowAFolderThatCannotBeSearchedIsInaccessibleNotMissing() async throws {
    let fixture = try await LocalRepositoryFixture()
    defer { fixture.remove() }
    let parent = fixture.root.appending(path: "parent", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let repository = try await fixture.addLinkedWorktree("parent/repo", branch: "side")
    let removedRepository = parent.appending(path: "gone").path
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: parent.path)

    let hidden = await Self.runScript(repository.path)
    let hiddenAndGone = await Self.runScript(removedRepository)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)

    #expect(throws: RemoteRepositoryRefreshError.inaccessibleFolder) { try RemoteRepositoryRefresh.parse(hidden) }
    #expect(throws: RemoteRepositoryRefreshError.inaccessibleFolder) {
      try RemoteRepositoryRefresh.parse(hiddenAndGone)
    }
    // Once the parent can be searched, the same path is found (a linked worktree, so not the
    // root), and the path that is gone is missing.
    let found = await Self.runScript(repository.path)
    let gone = await Self.runScript(removedRepository)
    #expect(throws: RemoteRepositoryRefreshError.notRepositoryRoot) { try RemoteRepositoryRefresh.parse(found) }
    #expect(throws: RemoteRepositoryRefreshError.missingFolder) { try RemoteRepositoryRefresh.parse(gone) }
  }

  /// The local host shows no line changes when `git diff HEAD` fails; the remote one agrees.
  @Test func aRepositoryWithoutACommitHasNoLineChanges() async throws {
    let fixture = try await LocalRepositoryFixture(commit: false)
    defer { fixture.remove() }
    try Data("new\n".utf8).write(to: fixture.main.appending(path: "untracked.txt"))

    let refresh = try RemoteRepositoryRefresh.parse(await Self.runScript(fixture.main.path))

    #expect(refresh.worktrees.count == 1)
    #expect(refresh.worktrees.first?.lineChanges == nil)
  }

  private static func runScript(_ path: String, searchPath: String? = nil) async -> RemoteCommandOutcome {
    let script = RemoteRepositoryRefresh.script(repositoryPath: path)
    guard let input = try? script.standardInput(path: searchPath ?? ProcessInfo.processInfo.environment["PATH"])
    else { return .launchFailed("invalid script") }
    return await RemoteCommandRunner.live.execute(
      URL(fileURLWithPath: "/bin/bash"), ["-s"], Data(input.utf8), .commandLane, nil)
  }

  /// `realpath`, as `pwd -P` resolves it: `resolvingSymlinksInPath` drops `/private`.
  private static func realpath(_ url: URL) throws -> String {
    let pointer = Darwin.realpath(url.path, nil)
    let resolved = try #require(pointer)
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private static func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "Fixtures/RemoteRepositoryRefresh/\(name).txt")
    return try String(contentsOf: url, encoding: .utf8)
  }
}

private struct RefreshExpectation {
  let path: String
  let searchPath: String?
  let error: RemoteRepositoryRefreshError
}

/// A repository in a temporary folder, made with this Mac's git.
private struct LocalRepositoryFixture {
  let root: URL
  let main: URL
  let git: GitExecutable

  init(commit: Bool = true) async throws {
    root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    main = root.appending(path: "main", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    git = try await GitExecutableResolver.shared.resolve()
    _ = try await git.run(["init", "-q", "-b", "trunk", main.path], shell: .live)
    guard commit else { return }
    try Data("one\ntwo\n".utf8).write(to: main.appending(path: "a.txt"))
    _ = try await git.run(["add", "a.txt"], in: main, shell: .live)
    _ = try await git.run(
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgSign=false",
        "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Initial",
      ], in: main, shell: .live)
  }

  @discardableResult
  func addLinkedWorktree(_ name: String, branch: String) async throws -> URL {
    let url = root.appending(path: name, directoryHint: .isDirectory)
    _ = try await git.run(["worktree", "add", "-q", "-b", branch, url.path], in: main, shell: .live)
    return url
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
