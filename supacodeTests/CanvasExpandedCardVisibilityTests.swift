import Foundation
import Testing

@testable import supacode

struct CanvasExpandedCardVisibilityTests {
  @Test func rendersAllCardsWhenNoCardIsExpanded() {
    let first = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let second = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    #expect(CanvasView.shouldRenderCard(first, expandedTabID: nil))
    #expect(CanvasView.shouldRenderCard(second, expandedTabID: nil))
  }

  @Test func rendersOnlyExpandedCardWhenMaxModeIsActive() {
    let expanded = TerminalTabID(
      rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let background = TerminalTabID(
      rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)

    #expect(CanvasView.shouldRenderCard(expanded, expandedTabID: expanded))
    #expect(!CanvasView.shouldRenderCard(background, expandedTabID: expanded))
  }
}
