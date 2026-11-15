import Foundation
import Testing

@testable import Prowl

/// `ShelfView` skips a spine's body when `==` holds, so `==` must change exactly when the body
/// can draw something else.
@MainActor
struct ShelfSpineEquatableTests {
  @Test func ignoresActionsButNotWhichActionsExist() {
    let spine = makeSpine(distance: 1, onSplit: nil)

    #expect(spine == makeSpine(distance: 1, onSplit: nil))
    #expect(spine != makeSpine(distance: 1, onSplit: {}))
  }

  @Test func distantSpinesStayEqualWhenTheOpenBookMoves() {
    #expect(makeSpine(distance: 6) == makeSpine(distance: 9))
    #expect(makeSpine(distance: 7) == makeSpine(distance: 6))
  }

  @Test func nearSpinesChangeWithTheTintLadder() {
    #expect(makeSpine(distance: 5) != makeSpine(distance: 6))
    #expect(makeSpine(distance: 1) != makeSpine(distance: 2))
    #expect(makeSpine(distance: nil) != makeSpine(distance: 0))
  }

  @Test func appearanceAndOpenStateAreCompared() {
    #expect(makeSpine(distance: 0, isOpen: true) != makeSpine(distance: 0, isOpen: false))
    #expect(
      makeSpine(distance: 2, appearance: RepositoryAppearance(icon: nil, color: .blue))
        != makeSpine(distance: 2)
    )
  }

  private func makeSpine(
    distance: Int?,
    isOpen: Bool = false,
    appearance: RepositoryAppearance = .empty,
    onSplit: (() -> Void)? = nil
  ) -> ShelfSpineView {
    ShelfSpineView(
      book: ShelfBook(
        id: "/tmp/repo/wt",
        repositoryID: "/tmp/repo",
        repositoryRootURL: nil,
        displayName: "wt",
        projectName: "repo",
        branchName: "wt",
        kind: .worktree
      ),
      isOpen: isOpen,
      distanceFromOpen: distance,
      terminalState: nil,
      activeAgentEntries: [],
      appearance: appearance,
      tintFallback: .neutral,
      followsRepositoryColor: true,
      onOpenBook: {},
      onSelectTab: { _ in },
      onSelectAgent: { _ in },
      onNewTab: {},
      onSplitVertical: onSplit,
      onSplitHorizontal: onSplit,
      closeMenuTitle: "Close Worktree",
      onCloseBook: {},
      onOpenRepositorySettings: {}
    )
  }
}
