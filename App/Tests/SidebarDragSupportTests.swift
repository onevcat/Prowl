import Testing

@testable import supacode

struct SidebarDragSupportTests {
  @Test func dropIndicatorOnlyDrawsOneEdgeForInteriorDestinations() {
    #expect(
      SidebarDropIndicatorEdge.edge(
        targetedDestination: 1,
        rowIndex: 0,
        rowCount: 3
      )
        == .none
    )
    #expect(
      SidebarDropIndicatorEdge.edge(
        targetedDestination: 1,
        rowIndex: 1,
        rowCount: 3
      )
        == .top
    )
  }

  @Test func dropIndicatorDrawsTopAndFinalBottomBoundaries() {
    #expect(
      SidebarDropIndicatorEdge.edge(
        targetedDestination: 0,
        rowIndex: 0,
        rowCount: 3
      )
        == .top
    )
    #expect(
      SidebarDropIndicatorEdge.edge(
        targetedDestination: 3,
        rowIndex: 2,
        rowCount: 3
      )
        == .bottom
    )
  }

  @Test func dropIndicatorHidesWithoutTarget() {
    #expect(
      SidebarDropIndicatorEdge.edge(
        targetedDestination: nil,
        rowIndex: 1,
        rowCount: 3
      )
        == .none
    )
  }
}
