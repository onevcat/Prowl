import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

@Suite("Agent account status")
struct AgentAccountStatusTests {
  @Test func claudeIdentityIsReadFromStatusPayload() {
    let output = """
      {
        "loggedIn": true,
        "authMethod": "claude.ai",
        "email": "person@example.com",
        "orgName": "Example",
        "subscriptionType": "pro"
      }
      """
    #expect(AgentAccountStatus.claudeState(fromOutput: output) == .signedIn("person@example.com (pro)"))
  }

  @Test func claudeFallsBackToOrganizationAndOmitsMissingPlan() {
    let output = #"{"loggedIn": true, "orgName": "Example"}"#
    #expect(AgentAccountStatus.claudeState(fromOutput: output) == .signedIn("Example"))
  }

  /// The exit code is non-zero when signed out, so only the payload distinguishes
  /// "signed out" from "could not ask".
  @Test func claudeSignedOutPayloadIsNotTreatedAsFailure() {
    #expect(AgentAccountStatus.claudeState(fromOutput: #"{"loggedIn": false}"#) == .signedOut)
  }

  @Test func claudeUnreadableOutputIsUnavailable() {
    #expect(AgentAccountStatus.claudeState(fromOutput: "zsh: command not found: claude") == .unavailable)
    #expect(AgentAccountStatus.claudeState(fromOutput: "") == .unavailable)
  }

  @Test func codexStatesAreReadFromItsSingleLine() {
    #expect(
      AgentAccountStatus.codexState(fromOutput: "Logged in using ChatGPT")
        == .signedIn("Logged in using ChatGPT")
    )
    #expect(AgentAccountStatus.codexState(fromOutput: "Not logged in\n") == .signedOut)
    #expect(AgentAccountStatus.codexState(fromOutput: "zsh: command not found: codex") == .unavailable)
    #expect(AgentAccountStatus.codexState(fromOutput: "  ") == .unavailable)
  }

  @Test func authCommandsCarryTheAccountDirectory() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "accounts")
    let claude = try #require(
      AgentAccountCLI.claude.command(.signIn, forAccountNamed: "work", accountsDirectory: root)
    )
    let codex = try #require(
      AgentAccountCLI.codex.command(.signIn, forAccountNamed: "work", accountsDirectory: root)
    )
    #expect(claude.hasSuffix(" claude auth login"))
    #expect(claude.contains("CLAUDE_CONFIG_DIR='"))
    #expect(claude.contains("/accounts/work/claude'"))
    #expect(codex.hasSuffix(" codex login"))
    #expect(codex.contains("/accounts/work/codex'"))

    let claudeOut = try #require(
      AgentAccountCLI.claude.command(.signOut, forAccountNamed: "work", accountsDirectory: root)
    )
    let codexOut = try #require(
      AgentAccountCLI.codex.command(.signOut, forAccountNamed: "work", accountsDirectory: root)
    )
    #expect(claudeOut.hasSuffix(" claude auth logout"))
    #expect(codexOut.hasSuffix(" codex logout"))

    // An unusable name resolves to no account at all, so there is nothing to run.
    #expect(
      AgentAccountCLI.claude.command(.signIn, forAccountNamed: "bad/name", accountsDirectory: root) == nil
    )
  }

  /// Regression: `codex login status` answers on stderr, and reading stdout alone
  /// reported an installed CLI as missing.
  @Test func statusIsReadFromWhicheverStreamTheCLIUses() {
    #expect(AgentAccountStatusClient.answer(stdout: "", stderr: "Not logged in") == "Not logged in")
    #expect(AgentAccountStatusClient.answer(stdout: "  \n", stderr: "Not logged in") == "Not logged in")
    let payload = #"{"loggedIn": false}"#
    #expect(AgentAccountStatusClient.answer(stdout: payload, stderr: "noise") == payload)
  }

  @MainActor
  @Test(.dependencies) func statusesAreLoadedForEveryConfiguredAccount() async {
    var settings = GlobalSettings.default
    settings.defaultAgentAccount = "personal"
    settings.agentAccountRules = [
      AgentAccountRule(pathPrefix: "~/work", account: "work"),
      // Duplicates and unusable names must not become their own rows.
      AgentAccountRule(pathPrefix: "~/other", account: "work"),
      AgentAccountRule(pathPrefix: "~/broken", account: "bad/name"),
    ]

    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentAccountStatusClient.self] = AgentAccountStatusClient { account in
        AgentAccountStatus(claude: .signedIn("\(account)@example.com"), codex: .signedOut)
      }
    }

    #expect(store.state.agentAccountNames == ["personal", "work"])

    await store.send(.refreshAgentAccountStatuses) {
      $0.isLoadingAgentAccountStatuses = true
    }
    await store.receive(\.agentAccountStatusesLoaded) {
      $0.isLoadingAgentAccountStatuses = false
      $0.agentAccountStatuses = [
        "personal": AgentAccountStatus(claude: .signedIn("personal@example.com"), codex: .signedOut),
        "work": AgentAccountStatus(claude: .signedIn("work@example.com"), codex: .signedOut),
      ]
    }
  }

  /// An account pinned by a single repository lives outside `GlobalSettings`, and
  /// without a login it is exactly the one that needs the Sign In button.
  @MainActor
  @Test(.dependencies) func repositoryScopedAccountsJoinTheList() async {
    var repositorySettings = RepositorySettings.default
    repositorySettings.agentAccount = "client"
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.repositories = ["/tmp/repo": repositorySettings] }
    // A repository whose settings live in its own prowl.json never reaches
    // settingsFile.repositories, so discovery has to ask the shared key too.
    let localRootURL = URL(fileURLWithPath: "/tmp/repo-local-\(UUID().uuidString)")
    @Shared(.repositoryEntries) var repositoryEntries
    $repositoryEntries.withLock {
      $0 = [PersistedRepositoryEntry(path: localRootURL.path(percentEncoded: false), kind: .git)]
    }
    @Shared(.repositorySettings(localRootURL)) var localSettings
    $localSettings.withLock { $0.agentAccount = "local-only" }

    let store = TestStore(initialState: SettingsFeature.State(settings: .default)) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentAccountStatusClient.self] = AgentAccountStatusClient { _ in
        AgentAccountStatus(claude: .signedOut, codex: .signedOut)
      }
    }
    store.exhaustivity = .off

    #expect(store.state.agentAccountNames.isEmpty)

    await store.send(.refreshAgentAccountStatuses)
    #expect(store.state.agentAccountNames == ["client", "local-only"])
    await store.receive(\.agentAccountStatusesLoaded)
    #expect(store.state.agentAccountStatuses["client"] != nil)
  }

  /// Every refresh spawns two login shells per account, so a second pass must
  /// replace the first instead of racing it to the same state.
  @MainActor
  @Test(.dependencies) func aSecondRefreshCancelsTheFirst() async {
    var settings = GlobalSettings.default
    settings.defaultAgentAccount = "personal"
    let started = LockIsolated(0)

    let store = TestStore(initialState: SettingsFeature.State(settings: settings)) {
      SettingsFeature()
    } withDependencies: {
      $0[AgentAccountStatusClient.self] = AgentAccountStatusClient { account in
        started.withValue { $0 += 1 }
        try? await Task.never()
        return AgentAccountStatus(claude: .signedIn(account), codex: .signedOut)
      }
    }
    store.exhaustivity = .off

    await store.send(.refreshAgentAccountStatuses)
    await store.send(.refreshAgentAccountStatuses)
    #expect(started.value == 2)

    // The empty-account path cancels the run instead of leaving the spinner on.
    await store.send(.binding(.set(\.defaultAgentAccount, "")))
    await store.send(.refreshAgentAccountStatuses) {
      $0.isLoadingAgentAccountStatuses = false
      $0.agentAccountStatuses = [:]
    }
    await store.finish()
  }

  @MainActor
  @Test(.dependencies) func signInButtonAsksTheAppToOpenALoginPane() async {
    let store = TestStore(initialState: SettingsFeature.State(settings: .default)) {
      SettingsFeature()
    }

    await store.send(.agentAccountAuthButtonTapped(account: "work", cli: .codex, action: .signIn))
    await store.receive(\.delegate.agentAccountAuth)
  }
}
