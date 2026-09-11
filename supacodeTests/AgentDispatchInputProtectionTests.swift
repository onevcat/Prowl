import Testing
@testable import supacode

struct AgentDispatchInputProtectionTests {
  @Test func markedTextNeverExpiresIntoPermissionToSend() {
    #expect(AgentDispatchInputProtection.refusal(hasMarkedText: true, lastEditingAt: 1, now: 100) != nil)
  }

  @Test func recentAndInvalidEditingEvidenceRefusesDelivery() {
    #expect(AgentDispatchInputProtection.refusal(hasMarkedText: false, lastEditingAt: 9, now: 10) != nil)
    #expect(AgentDispatchInputProtection.refusal(hasMarkedText: false, lastEditingAt: 11, now: 10) != nil)
    #expect(AgentDispatchInputProtection.refusal(hasMarkedText: false, lastEditingAt: .nan, now: 10) != nil)
    #expect(AgentDispatchInputProtection.refusal(hasMarkedText: false, lastEditingAt: 8, now: 10) == nil)
    #expect(AgentDispatchInputProtection.refusal(hasMarkedText: false, lastEditingAt: nil, now: 10) == nil)
  }
}
