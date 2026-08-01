import Foundation
import Testing

@testable import supacode

@MainActor
struct HandoffRequestRegistryTests {
  private let sourcePaneID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
  private let otherPaneID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
  private let profileID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!

  private var profileHandoff: HandoffRequestExpectation {
    HandoffRequestExpectation(
      sourcePaneID: sourcePaneID,
      operation: .handoff(target: .profile(profileID))
    )
  }

  @Test func exactRequestCanBeClaimedOnlyOnce() {
    let registry = HandoffRequestRegistry()
    let requestID = UUID()

    registry.register(requestID, expectation: profileHandoff)

    #expect(registry.claim(requestID, actual: profileHandoff) == .claimed)
    #expect(registry.claim(requestID, actual: profileHandoff) == .unavailable)
  }

  @Test func mismatchDoesNotConsumePendingRequest() {
    let registry = HandoffRequestRegistry()
    let requestID = UUID()
    registry.register(requestID, expectation: profileHandoff)
    let wrongPane = HandoffRequestExpectation(
      sourcePaneID: otherPaneID,
      operation: profileHandoff.operation
    )
    let wrongTarget = HandoffRequestExpectation(
      sourcePaneID: sourcePaneID,
      operation: .handoff(target: .runtimeDefault(.codex))
    )

    #expect(registry.claim(requestID, actual: wrongPane) == .mismatch)
    #expect(registry.claim(requestID, actual: wrongTarget) == .mismatch)
    #expect(registry.claim(requestID, actual: profileHandoff) == .claimed)
  }

  @Test func unknownAndSupersededRequestsAreUnavailable() {
    let registry = HandoffRequestRegistry()
    let requestID = UUID()

    #expect(registry.claim(requestID, actual: profileHandoff) == .unavailable)
    registry.register(requestID, expectation: profileHandoff)

    #expect(registry.supersede(requestID))
    #expect(registry.claim(requestID, actual: profileHandoff) == .unavailable)
  }

  @Test func duplicateRegistrationCannotReplaceOrReopenARequest() {
    let registry = HandoffRequestRegistry()
    let requestID = UUID()
    let checkpoint = HandoffRequestExpectation(
      sourcePaneID: sourcePaneID,
      operation: .checkpoint
    )

    registry.register(requestID, expectation: profileHandoff)
    registry.register(requestID, expectation: checkpoint)
    #expect(registry.claim(requestID, actual: checkpoint) == .mismatch)
    #expect(registry.claim(requestID, actual: profileHandoff) == .claimed)

    #expect(!registry.supersede(requestID))
    registry.register(requestID, expectation: checkpoint)
    #expect(registry.claim(requestID, actual: checkpoint) == .unavailable)
  }

  @Test func profileInjectionCarriesUUIDAndExplicitSourcePane() {
    let requestID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!

    let instruction = HandoffInjection.instruction(
      for: profileHandoff,
      requestID: requestID
    )

    #expect(instruction.contains("prowl handoff to --agent-profile-id \(profileID.uuidString)"))
    #expect(instruction.contains("--pane \(sourcePaneID.uuidString) --brief -"))
    #expect(instruction.contains("\(HandoffInput.requestIDEnvironmentKey)=\(requestID.uuidString)"))
    #expect(!instruction.contains("\n"))
  }

  @Test func runtimeAndCheckpointInjectionsCarryExplicitSourcePane() {
    let requestID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
    let runtime = HandoffRequestExpectation(
      sourcePaneID: sourcePaneID,
      operation: .handoff(target: .runtimeDefault(.claude))
    )
    let checkpoint = HandoffRequestExpectation(
      sourcePaneID: sourcePaneID,
      operation: .checkpoint
    )

    let runtimeInstruction = HandoffInjection.instruction(for: runtime, requestID: requestID)
    let checkpointInstruction = HandoffInjection.instruction(for: checkpoint, requestID: requestID)

    #expect(
      runtimeInstruction.contains(
        "prowl handoff to claude --pane \(sourcePaneID.uuidString) --brief -"
      )
    )
    #expect(
      checkpointInstruction.contains(
        "prowl handoff save --pane \(sourcePaneID.uuidString) --brief -"
      )
    )
  }
}
