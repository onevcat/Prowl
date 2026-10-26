import Foundation
import Testing

@testable import Prowl

private struct StubLLMService: LLMService {
  let output: String
  var isAvailable: Bool { true }
  // swiftlint:disable:next async_without_await
  func generate(prompt: String) async throws -> String { output }
}

struct BranchNameSanitizerTests {
  // MARK: - sanitize

  @Test func sanitizeTrimsLowercasesAndHyphenatesWhitespace() {
    #expect(BranchNameSanitizer.sanitize("  Add Login  Page \n") == "add-login-page")
  }

  @Test func sanitizeKeepsOnlyTheFirstLineOfMultiLineOutput() {
    #expect(BranchNameSanitizer.sanitize("feat/add-login\nThis branch adds a login page.") == "feat/add-login")
  }

  @Test func sanitizeReplacesUnderscoresAndDropsInvalidCharacters() {
    #expect(BranchNameSanitizer.sanitize("fix_crash~^:?*[]\\@{}") == "fix-crash")
  }

  @Test func sanitizeCollapsesRepeatsAndStripsLeadingAndTrailingSeparators() {
    #expect(BranchNameSanitizer.sanitize("--foo..bar--.lock") == "foo.bar")
  }

  @Test func sanitizeRejectsNamesShorterThanThreeCharacters() {
    #expect(BranchNameSanitizer.sanitize("") == nil)
    #expect(BranchNameSanitizer.sanitize("ab") == nil)
    #expect(BranchNameSanitizer.sanitize(" -a- ") == nil)
  }

  @Test func sanitizeTruncatesToMaxLengthWithoutTrailingSeparator() {
    let raw = String(repeating: "a", count: 49) + "-bcd"
    #expect(BranchNameSanitizer.sanitize(raw) == String(repeating: "a", count: 49))
  }

  // MARK: - detectConventionPrefix

  @Test func detectsPrefixOutsideTheCommonList() {
    #expect(BranchNameSanitizer.detectConventionPrefix(from: ["feat/a", "feat/b", "main"]) == "feat/")
    #expect(BranchNameSanitizer.detectConventionPrefix(from: ["onevcat/a", "main"]) == "onevcat/")
  }

  @Test func detectsCommonPrefix() {
    #expect(BranchNameSanitizer.detectConventionPrefix(from: ["main", "feature/a"]) == "feature/")
  }

  @Test func detectsTheMostFrequentPrefix() {
    let branches = ["main", "fix/a", "feat/b", "feat/c", "feat/d/e"]
    #expect(BranchNameSanitizer.detectConventionPrefix(from: branches) == "feat/")
  }

  @Test func detectsNoPrefixWithoutSlashedBranches() {
    #expect(BranchNameSanitizer.detectConventionPrefix(from: []) == nil)
    #expect(BranchNameSanitizer.detectConventionPrefix(from: ["main", "develop"]) == nil)
  }

  @Test func detectsNoPrefixWhenNoneDominates() {
    #expect(BranchNameSanitizer.detectConventionPrefix(from: ["feature/a", "fix/b", "main"]) == nil)
  }

  @Test func detectsPrefixFromBranchesAfterRemotePrefixesAreRemoved() {
    let names = BranchNameSanitizer.branchNames(
      fromRefs: ["main", "origin/feat/a", "origin/feat/b", "origin/main", "origin/fix/c"],
      remotes: ["origin"]
    )
    #expect(BranchNameSanitizer.detectConventionPrefix(from: names) == "feat/")
  }

  @Test func ignoresBranchesWithAnEmptyFirstSegment() {
    #expect(BranchNameSanitizer.detectConventionPrefix(from: ["/a", "/b", "feat/c"]) == "feat/")
  }

  // MARK: - branchNames(fromRefs:remotes:)

  @Test func branchNamesStripRemotePrefixesAndDropDuplicates() {
    let names = BranchNameSanitizer.branchNames(
      fromRefs: ["feat/a", "main", "origin/feat/a", "origin/main", "upstream/fix/b"],
      remotes: ["origin", "upstream"]
    )
    #expect(names == ["feat/a", "main", "fix/b"])
  }

  @Test func branchNamesUseTheLongestMatchingRemote() {
    let names = BranchNameSanitizer.branchNames(
      fromRefs: ["team/origin/feat/a", "team/main"],
      remotes: ["team", "team/origin"]
    )
    #expect(names == ["feat/a", "main"])
  }

  @Test func branchNamesKeepRefsWithoutAKnownRemote() {
    #expect(BranchNameSanitizer.branchNames(fromRefs: ["feat/a", "HEAD"], remotes: []) == ["feat/a", "HEAD"])
  }

  // MARK: - ensurePrefix

  @Test func ensurePrefixKeepsNamesThatAlreadyHaveOne() {
    #expect(BranchNameSanitizer.ensurePrefix("fix/crash", conventionPrefix: "feat/") == "fix/crash")
  }

  @Test func ensurePrefixAppliesConventionOrFallsBackToWorktree() {
    #expect(BranchNameSanitizer.ensurePrefix("crash", conventionPrefix: "feat/") == "feat/crash")
    #expect(BranchNameSanitizer.ensurePrefix("crash", conventionPrefix: nil) == "worktree/crash")
  }

  // MARK: - validate

  @Test func validateUsesThePrefixOfTheRepositoryBranches() {
    let branches = ["main", "feat/onboarding", "feat/settings"]
    #expect(BranchNameSanitizer.validate("Add Login", existingBranches: branches) == "feat/add-login")
  }

  @Test func validateKeepsAPrefixTheModelChose() {
    let branches = ["main", "feat/onboarding"]
    #expect(BranchNameSanitizer.validate("fix/login-crash", existingBranches: branches) == "fix/login-crash")
  }

  @Test func validateFallsBackToWorktreePrefix() {
    #expect(BranchNameSanitizer.validate("add-login", existingBranches: []) == "worktree/add-login")
    #expect(BranchNameSanitizer.validate("add-login", existingBranches: ["main"]) == "worktree/add-login")
  }

  @Test func validateRejectsExistingBranchesCaseInsensitively() {
    let branches = ["main", "Feat/Add-Login", "feat/other"]
    #expect(BranchNameSanitizer.validate("feat/add-login", existingBranches: branches) == nil)
  }

  @Test func validateRejectsNamesTooLongAfterPrefixing() {
    let name = String(repeating: "a", count: 45)
    #expect(BranchNameSanitizer.validate(name, existingBranches: []) == nil)
  }

  @Test func validateRejectsUnusableOutput() {
    #expect(BranchNameSanitizer.validate("??", existingBranches: ["feat/a"]) == nil)
  }

  // MARK: - Prompt alignment

  @Test func promptListsPrefixesMostFrequentFirst() {
    let context = BranchNameSuggestionContext(
      repositoryName: "demo",
      existingBranchNames: ["fix/a", "main", "feat/b", "chore/c", "feat/d"],
      terminalContexts: [],
      llmAvailable: true
    )
    let prompt = BranchNameSuggestionClient.buildPrompt(from: context)
    #expect(prompt.contains("Existing branches use prefixes: feat/, fix/, chore/."))
  }

  @Test func promptDerivesPrefixesFromAllBranchesButListsOnlyTen() {
    let unprefixed = (1...10).map { "topic-\($0)" }
    let context = BranchNameSuggestionContext(
      repositoryName: "demo",
      existingBranchNames: unprefixed + ["feat/a", "feat/b"],
      terminalContexts: [],
      llmAvailable: true
    )
    let prompt = BranchNameSuggestionClient.buildPrompt(from: context)
    #expect(prompt.contains("Existing branches use prefixes: feat/."))
    #expect(prompt.hasSuffix("Existing branches: \(unprefixed.joined(separator: ", "))"))
  }

  @Test func promptListsAtMostFivePrefixes() {
    let context = BranchNameSuggestionContext(
      repositoryName: "demo",
      existingBranchNames: ["a/1", "a/2", "b/1", "c/1", "d/1", "e/1", "f/1"],
      terminalContexts: [],
      llmAvailable: true
    )
    let prompt = BranchNameSuggestionClient.buildPrompt(from: context)
    #expect(prompt.contains("Existing branches use prefixes: a/, b/, c/, d/, e/."))
  }

  @Test @MainActor func liveSuggestionUsesBranchesBeyondTheFirstTen() async {
    let client = BranchNameSuggestionClient.live(llmService: StubLLMService(output: "Add Login"))
    let branches = (1...10).map { "topic-\($0)" } + ["feat/a", "feat/b"]
    let context = client.gatherContext("demo", .local(URL(fileURLWithPath: "/tmp/demo")), branches)
    #expect(await client.suggest(context) == "feat/add-login")
  }
}
