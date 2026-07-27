import Foundation
import Testing

@testable import supacode

@Suite("AgentAccount")
struct AgentAccountTests {
  private let rules = [
    AgentAccountRule(pathPrefix: "/Users/dev/work", account: "work"),
    AgentAccountRule(pathPrefix: "/Users/dev/work/client", account: "client"),
  ]

  @Test func repositoryOverrideWinsOverRuleAndDefault() {
    let account = AgentAccount.resolvedName(
      repositoryRootURL: URL(fileURLWithPath: "/Users/dev/work/app"),
      repositoryOverride: "personal",
      globalDefault: "fallback",
      rules: rules
    )
    #expect(account == "personal")
  }

  @Test func longestMatchingRuleWins() {
    let account = AgentAccount.resolvedName(
      repositoryRootURL: URL(fileURLWithPath: "/Users/dev/work/client/app"),
      repositoryOverride: nil,
      globalDefault: "fallback",
      rules: rules
    )
    #expect(account == "client")
  }

  /// Regression: rules matched only paths that do not exist on disk, because
  /// `URL(fileURLWithPath:)` appends a trailing slash for real directories.
  @Test func ruleMatchesWhenBothPathsExistOnDisk() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "prowl-rules-\(UUID().uuidString)", directoryHint: .isDirectory)
    let repositoryRoot = base.appending(path: "work/app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let account = AgentAccount.resolvedName(
      repositoryRootURL: URL(fileURLWithPath: repositoryRoot.path(percentEncoded: false)),
      repositoryOverride: nil,
      globalDefault: "fallback",
      rules: [
        AgentAccountRule(
          pathPrefix: base.appending(path: "work", directoryHint: .isDirectory).path(percentEncoded: false),
          account: "work"
        )
      ]
    )
    #expect(account == "work")
  }

  @Test func rulesOfEqualLengthResolveToTheFirstOne() {
    let account = AgentAccount.resolvedName(
      repositoryRootURL: URL(fileURLWithPath: "/Users/dev/work/app"),
      repositoryOverride: nil,
      globalDefault: nil,
      rules: [
        AgentAccountRule(pathPrefix: "/Users/dev/work", account: "first"),
        AgentAccountRule(pathPrefix: "/Users/dev/work/", account: "second"),
      ]
    )
    #expect(account == "first")
  }

  @Test func ruleMatchesOnPathBoundaryOnly() {
    let account = AgentAccount.resolvedName(
      repositoryRootURL: URL(fileURLWithPath: "/Users/dev/workshop/app"),
      repositoryOverride: nil,
      globalDefault: "fallback",
      rules: rules
    )
    #expect(account == "fallback")
  }

  @Test func fallsBackToSystemAccountWhenNothingIsConfigured() {
    let account = AgentAccount.resolvedName(
      repositoryRootURL: URL(fileURLWithPath: "/Users/dev/personal/app"),
      repositoryOverride: "   ",
      globalDefault: nil,
      rules: []
    )
    #expect(account == nil)
  }

  @Test func namesThatWouldEscapeTheAccountsDirectoryAreRejected() {
    #expect(AgentAccount.normalizedName("../../etc") == nil)
    #expect(AgentAccount.normalizedName("work/child") == nil)
    #expect(AgentAccount.normalizedName("..") == nil)
    #expect(AgentAccount.normalizedName("  work  ") == "work")
  }

  @Test func unusableNamesSurvivePersistenceSoTypedInputIsNeverDropped() {
    #expect(AgentAccount.storedName("work/child") == "work/child")
    #expect(AgentAccount.storedName("  work  ") == "work")
    #expect(AgentAccount.storedName("   ") == nil)
    #expect(AgentAccount.storedName(nil) == nil)
  }

  @Test func unusableRuleAccountIsIgnoredWithoutFallingBackToAnotherRule() {
    let account = AgentAccount.resolvedName(
      repositoryRootURL: URL(fileURLWithPath: "/Users/dev/work/app"),
      repositoryOverride: nil,
      globalDefault: "fallback",
      rules: [AgentAccountRule(pathPrefix: "/Users/dev/work", account: "bad/name")]
    )
    #expect(account == "fallback")
  }

  @Test func environmentPointsBothCLIsAtTheAccountDirectory() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "prowl-accounts-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let environment = AgentAccount.environment(forAccountNamed: "work", accountsDirectory: root)

    #expect(environment["CLAUDE_CONFIG_DIR"] == root.appending(path: "work/claude").path(percentEncoded: false))
    #expect(environment["CODEX_HOME"] == root.appending(path: "work/codex").path(percentEncoded: false))
    // Building the environment must stay pure.
    #expect(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
  }

  @Test func prepareDirectoriesCreatesBothConfigDirectories() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "prowl-accounts-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    try AgentAccount.prepareDirectories(forAccountNamed: "work", accountsDirectory: root)

    // `codex` refuses to start when CODEX_HOME does not exist yet.
    for path in AgentAccount.environment(forAccountNamed: "work", accountsDirectory: root).values {
      #expect(FileManager.default.fileExists(atPath: path))
    }
  }

  /// Relocating `CLAUDE_CONFIG_DIR` moves the whole configuration, so without
  /// these links an account is an empty profile: no permissions, hooks or agents.
  @Test func sharedConfigIsLinkedIntoAnAccountWithoutTouchingWhatItOwns() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "prowl-shared-\(UUID().uuidString)", directoryHint: .isDirectory)
    let source = root.appending(path: "source", directoryHint: .isDirectory)
    let account = root.appending(path: "account", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: source.appending(path: "agents"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
    try "shared".write(to: source.appending(path: "settings.json"), atomically: true, encoding: .utf8)
    try "mine".write(to: account.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)

    AgentAccount.linkSharedConfig(
      into: account,
      from: source,
      entries: ["settings.json", "agents", "CLAUDE.md", "commands"]
    )

    let settingsPath = account.appending(path: "settings.json").path(percentEncoded: false)
    let agentsPath = account.appending(path: "agents").path(percentEncoded: false)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: settingsPath).hasSuffix("settings.json"))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: agentsPath).hasSuffix("agents"))
    // A file the account already owns stays its own, and a missing source is skipped.
    #expect(try String(contentsOf: account.appending(path: "CLAUDE.md"), encoding: .utf8) == "mine")
    #expect(!FileManager.default.fileExists(atPath: account.appending(path: "commands").path(percentEncoded: false)))
  }

  /// A link a tool replaced with a copy looks identical from the outside, so the
  /// account silently stops following the user's configuration.
  @Test func anAccountKeepingItsOwnCopyOfSharedConfigIsReported() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "prowl-diverged-\(UUID().uuidString)", directoryHint: .isDirectory)
    let source = root.appending(path: "source", directoryHint: .isDirectory)
    let account = root.appending(path: "account", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
    try "shared".write(to: source.appending(path: "settings.json"), atomically: true, encoding: .utf8)
    try "shared".write(to: source.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
    try "own".write(to: account.appending(path: "settings.json"), atomically: true, encoding: .utf8)
    AgentAccount.linkSharedConfig(into: account, from: source, entries: ["settings.json", "CLAUDE.md"])

    let diverged = AgentAccount.divergedEntries(
      in: account,
      from: source,
      entries: ["settings.json", "CLAUDE.md"]
    )

    #expect(diverged == ["settings.json"])
  }

  @Test func environmentIsEmptyForTheSystemAccount() {
    #expect(AgentAccount.environment(forAccountNamed: nil).isEmpty)
    #expect(AgentAccount.environment(forAccountNamed: "").isEmpty)
    #expect(AgentAccount.environment(forAccountNamed: "bad/name").isEmpty)
  }

  @Test func tildeInRulePathIsExpanded() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    let account = AgentAccount.resolvedName(
      repositoryRootURL: URL(fileURLWithPath: home).appending(path: "work/app"),
      repositoryOverride: nil,
      globalDefault: nil,
      rules: [AgentAccountRule(pathPrefix: "~/work", account: "work")]
    )
    #expect(account == "work")
  }
}
