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

  /// `claude auth status` exits non-zero when signed out, so only the payload
  /// distinguishes "signed out" from "could not ask".
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
    let claude = try #require(AgentAccountCLI.claude.command(.signIn, forAccountNamed: "work"))
    let codex = try #require(AgentAccountCLI.codex.command(.signIn, forAccountNamed: "work"))
    #expect(claude.hasSuffix(" claude auth login"))
    #expect(claude.contains("CLAUDE_CONFIG_DIR='"))
    #expect(claude.contains("/accounts/work/claude'"))
    #expect(codex.hasSuffix(" codex login"))
    #expect(codex.contains("/accounts/work/codex'"))

    let claudeOut = try #require(AgentAccountCLI.claude.command(.signOut, forAccountNamed: "work"))
    let codexOut = try #require(AgentAccountCLI.codex.command(.signOut, forAccountNamed: "work"))
    #expect(claudeOut.hasSuffix(" claude auth logout"))
    #expect(codexOut.hasSuffix(" codex logout"))

    // An unusable name resolves to no account at all, so there is nothing to run.
    #expect(AgentAccountCLI.claude.command(.signIn, forAccountNamed: "bad/name") == nil)
  }

  /// `codex login status` answers on stderr with an empty stdout, so reading only
  /// stdout reported an installed CLI as missing.
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

  @MainActor
  @Test(.dependencies) func signInButtonAsksTheAppToOpenALoginPane() async {
    let store = TestStore(initialState: SettingsFeature.State(settings: .default)) {
      SettingsFeature()
    }

    await store.send(.agentAccountAuthButtonTapped(account: "work", cli: .codex, action: .signIn))
    await store.receive(\.delegate.agentAccountAuth)
  }
}
