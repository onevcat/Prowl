import Foundation
import Testing

@testable import supacode

@MainActor
struct TerminalTargetHandleRegistryTests {
  @Test func allocatesGloballyAndNeverReusesClosedTargets() {
    let registry = TerminalTargetHandleRegistry()
    let tabID = TerminalTabID(rawValue: UUID())
    let paneID = UUID()

    #expect(registry.register(tabID: tabID) == 1)
    #expect(registry.register(paneID: paneID) == 2)
    #expect(registry.register(tabID: tabID) == 1)

    registry.unregister(tabID: tabID)
    registry.unregister(paneID: paneID)

    #expect(registry.handle(for: tabID) == nil)
    #expect(registry.handle(for: paneID) == nil)
    #expect(registry.register(tabID: tabID) == 3)
    #expect(registry.register(paneID: paneID) == 4)
  }
}
