import Testing

@testable import supacode

struct DetectedAgentTests {
  @Test func displayNamesUseCommandStyleTokens() {
    for agent in DetectedAgent.allCases {
      let expectedDisplayName = agent == .cursor ? "cursor" : agent.rawValue
      #expect(agent.displayName == expectedDisplayName)
    }
  }
}
