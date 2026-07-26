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

  /// Regression: `URL(fileURLWithPath:)` appends a trailing slash for directories
  /// that exist, which silently stopped every rule from matching a real
  /// repository while tests using imaginary paths stayed green.
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
    // Building the environment must stay pure: only `prepareDirectories` touches disk.
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
