import CoreGraphics
import Foundation
import Testing

@testable import supacode

struct AgentIslandRosterContentTests {
  @Test func pageLayoutShowsNineRowsAndClampsThePage() {
    #expect(AgentIslandRosterLayout.layout(entryCount: 20, requestedPageIndex: 0).entryRange == 0..<9)
    #expect(AgentIslandRosterLayout.layout(entryCount: 20, requestedPageIndex: 1).entryRange == 9..<18)

    let lastPage = AgentIslandRosterLayout.layout(entryCount: 20, requestedPageIndex: 99)
    #expect(lastPage.pageIndex == 2)
    #expect(lastPage.pageCount == 3)
    #expect(lastPage.entryRange == 18..<20)
  }

  @Test func emptyPageLayoutHasNoRowsOrPages() {
    let layout = AgentIslandRosterLayout.layout(entryCount: 0, requestedPageIndex: 4)

    #expect(layout.pageIndex == 0)
    #expect(layout.pageCount == 0)
    #expect(layout.entryRange.isEmpty)
  }
}
