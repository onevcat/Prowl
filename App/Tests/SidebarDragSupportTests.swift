import Foundation
import Testing

@testable import Prowl

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

  // MARK: - Sidebar layout drops (docs-ai 086 S2)

  private let group = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
  private var groupKey: String { SidebarLayoutItem.groupKey(group) }

  @Test func aRepositoryRowSplitsAtItsHeader() {
    let row = SidebarDropRow.repository(key: "/a", nextKey: groupKey)

    #expect(row.destination(for: .repository("/x"), locationY: 10) == .topLevel(before: "/a"))
    #expect(row.destination(for: .repository("/x"), locationY: 40) == .topLevel(before: groupKey))
    #expect(row.destination(for: .group(group), locationY: 10) == .topLevel(before: "/a"))
  }

  @Test func aGroupHeaderTakesARepositoryAtTheGroupEnd() {
    let row = SidebarDropRow.groupHeader(group, nextKey: "/d")

    #expect(row.destination(for: .repository("/x"), locationY: 4) == .topLevel(before: groupKey))
    #expect(row.destination(for: .repository("/x"), locationY: 14) == .group(group, before: nil))
  }

  @Test func aGroupHeaderPutsAGroupBeforeOrAfterIt() {
    let row = SidebarDropRow.groupHeader(group, nextKey: "/d")
    let other = UUID()

    #expect(row.destination(for: .group(other), locationY: 6) == .topLevel(before: groupKey))
    #expect(row.destination(for: .group(other), locationY: 20) == .topLevel(before: "/d"))
  }

  @Test func aGroupMemberRowSplitsInTheGroup() {
    let row = SidebarDropRow.groupMember(group, repositoryID: "/b", nextMemberID: "/c", nextKey: "/d")

    #expect(row.destination(for: .repository("/x"), locationY: 10) == .group(group, before: "/b"))
    #expect(row.destination(for: .repository("/x"), locationY: 40) == .group(group, before: "/c"))
  }

  @Test func aGroupMemberRowPutsAGroupAfterTheContainingGroup() {
    let row = SidebarDropRow.groupMember(group, repositoryID: "/c", nextMemberID: nil, nextKey: nil)

    #expect(row.destination(for: .repository("/x"), locationY: 40) == .group(group, before: nil))
    #expect(row.destination(for: .group(UUID()), locationY: 10) == .topLevel(before: nil))
  }

  @Test func theEmptyGroupPlaceholderAndTheListEnd() {
    let placeholder = SidebarDropRow.emptyGroup(group, nextKey: "/d")

    #expect(placeholder.destination(for: .repository("/x"), locationY: 0) == .group(group, before: nil))
    #expect(placeholder.destination(for: .group(UUID()), locationY: 0) == .topLevel(before: "/d"))
    #expect(SidebarDropRow.listEnd.destination(for: .repository("/x"), locationY: 0) == .topLevel(before: nil))
    #expect(SidebarDropRow.listEnd.destination(for: .group(group), locationY: 0) == .topLevel(before: nil))
  }

  @Test func layoutDropIndicatorEdges() {
    let top = SidebarDropDestination.topLevel(before: "/a")
    let bottom = SidebarDropDestination.topLevel(before: nil)

    #expect(SidebarDropIndicatorEdge.edge(targetedDestination: top, top: top, bottom: bottom) == .top)
    #expect(SidebarDropIndicatorEdge.edge(targetedDestination: bottom, top: top, bottom: bottom) == .bottom)
    #expect(SidebarDropIndicatorEdge.edge(targetedDestination: bottom, top: top, bottom: nil) == .none)
    #expect(SidebarDropIndicatorEdge.edge(targetedDestination: nil, top: top, bottom: bottom) == .none)
  }

  @Test func aDestinationKnowsItsGroup() {
    #expect(SidebarDropDestination.group(group, before: nil).groupID == group)
    #expect(SidebarDropDestination.topLevel(before: groupKey).groupID == nil)
  }
}
