import Foundation
import ProwlCLIShared
import Testing

@testable import Prowl

struct AgentLaunchEnvironmentAssignmentTests {
  @Test func assignmentsRenderTheLocalShellTokens() {
    #expect(
      AgentLaunchEnvironmentAssignment.literal(name: "CODEX_HOME", value: "/base/a b").token == "CODEX_HOME='/base/a b'"
    )
    #expect(AgentLaunchEnvironmentAssignment.literal(name: "X", value: "it's").token == #"X='it'"'"'s'"#)
    #expect(
      AgentLaunchEnvironmentAssignment.carrier(name: "OPENAI_API_KEY", carrier: "PROWL_ENV_OPENAI_API_KEY").token
        == #"OPENAI_API_KEY="$PROWL_ENV_OPENAI_API_KEY""#)
    #expect(AgentLaunchEnvironmentAssignment.carrier(name: "A", carrier: "B").name == "A")
  }

  @Test func plannerAndDispatchKeepTheMeaningOfEachAssignment() throws {
    let base = URL(fileURLWithPath: "/base", isDirectory: true)
    var profile = AgentProfile(name: "Codex · Work", runtime: .codex, bindsDedicatedHome: true)
    profile.environmentOverrides = [
      AgentProfileEnvironmentOverride(name: "OPENAI_BASE_URL", value: "https://example.invalid")
    ]

    let plan = try AgentProfileLaunchPlanner.plan(for: profile, intent: .prompt("hello"), homeBaseDirectory: base)
      .attachingDispatch(id: "dispatch-1", userPrompt: "hello")

    let home = AgentProfileLaunchPlanner.pathString(
      AgentProfileLaunchPlanner.dedicatedHomeDirectory(for: profile.id, base: base))
    #expect(
      plan.commandEnvironment == [
        .literal(name: "CODEX_HOME", value: home),
        .carrier(name: "OPENAI_BASE_URL", carrier: "PROWL_ENV_OPENAI_BASE_URL"),
        .carrier(name: DispatchCompleteInput.environmentKey, carrier: AgentProfileLaunchPlanner.dispatchCarrierName),
      ])
    #expect(
      plan.commandEnvironmentTokens == [
        "CODEX_HOME='\(home)'",
        #"OPENAI_BASE_URL="$PROWL_ENV_OPENAI_BASE_URL""#,
        "\(DispatchCompleteInput.environmentKey)=\"$\(AgentProfileLaunchPlanner.dispatchCarrierName)\"",
      ])
    // The override value stays out of the typed command.
    #expect(!plan.terminalInput.contains("example.invalid"))
  }
}
