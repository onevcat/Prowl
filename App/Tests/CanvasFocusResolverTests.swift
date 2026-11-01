import Foundation
import Testing

@testable import Prowl

struct CanvasFocusResolverTests {
  @Test func worktreeTargetSelectsFirstCardWhenNothingIsFocused() {
    let worktreeID = "/tmp/repo/main"
    let first = TerminalTabID(rawValue: UUID())
    let second = TerminalTabID(rawValue: UUID())

    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .worktree(worktreeID)),
      candidates: [
        CanvasCardRef(worktreeID: worktreeID, tabID: first),
        CanvasCardRef(worktreeID: worktreeID, tabID: second),
      ],
      currentPrimaryTabID: nil
    )

    #expect(resolved == first)
  }

  @Test func worktreeTargetCyclesFromFocusedCardToNextMatch() {
    let worktreeID = "/tmp/repo/main"
    let first = TerminalTabID(rawValue: UUID())
    let second = TerminalTabID(rawValue: UUID())
    let other = TerminalTabID(rawValue: UUID())

    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .worktree(worktreeID)),
      candidates: [
        CanvasCardRef(worktreeID: worktreeID, tabID: first),
        CanvasCardRef(worktreeID: "/tmp/other/main", tabID: other),
        CanvasCardRef(worktreeID: worktreeID, tabID: second),
      ],
      currentPrimaryTabID: first
    )

    #expect(resolved == second)
  }

  @Test func worktreeTargetWrapsFromLastFocusedCardToFirstMatch() {
    let worktreeID = "/tmp/repo/main"
    let first = TerminalTabID(rawValue: UUID())
    let second = TerminalTabID(rawValue: UUID())

    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .worktree(worktreeID)),
      candidates: [
        CanvasCardRef(worktreeID: worktreeID, tabID: first),
        CanvasCardRef(worktreeID: worktreeID, tabID: second),
      ],
      currentPrimaryTabID: second
    )

    #expect(resolved == first)
  }

  @Test func tabTargetSelectsExactVisibleCard() {
    let requested = TerminalTabID(rawValue: UUID())

    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .tab(requested)),
      candidates: [
        CanvasCardRef(worktreeID: "/tmp/repo/main", tabID: TerminalTabID(rawValue: UUID())),
        CanvasCardRef(worktreeID: "/tmp/repo/main", tabID: requested),
      ],
      currentPrimaryTabID: nil
    )

    #expect(resolved == requested)
  }

  @Test func tabTargetWaitsWhenExactCardIsNotVisibleYet() {
    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .tab(TerminalTabID(rawValue: UUID()))),
      candidates: [
        CanvasCardRef(worktreeID: "/tmp/repo/main", tabID: TerminalTabID(rawValue: UUID()))
      ],
      currentPrimaryTabID: nil
    )

    #expect(resolved == nil)
  }
}

struct CanvasNewCardFocusTests {
  private let first = CanvasCardRef(worktreeID: "/tmp/repo/a", tabID: TerminalTabID(rawValue: UUID()))
  private let second = CanvasCardRef(worktreeID: "/tmp/repo/a", tabID: TerminalTabID(rawValue: UUID()))
  private let other = CanvasCardRef(worktreeID: "/tmp/repo/b", tabID: TerminalTabID(rawValue: UUID()))

  @Test func followsTheLastForegroundNewCard() {
    let card = CanvasNewCardFocus.cardToFollow(
      newKeys: [first.key, second.key, other.key],
      cards: [first, second, other],
      foregroundTabIDs: [second.tabID, other.tabID]
    )

    #expect(card == other)
  }

  @Test func ignoresBackgroundCreations() {
    // A background tab in a worktree without tabs becomes its selected tab; it
    // still must not take focus.
    let card = CanvasNewCardFocus.cardToFollow(
      newKeys: [first.key],
      cards: [first],
      foregroundTabIDs: []
    )

    #expect(card == nil)
  }

  @Test func ignoresForegroundTabsThatAreNotNewCards() {
    let card = CanvasNewCardFocus.cardToFollow(
      newKeys: [second.key],
      cards: [first, second],
      foregroundTabIDs: [first.tabID]
    )

    #expect(card == nil)
  }

  @Test func selectedTabTargetUsesTheWorktreeSelectedTab() {
    let first = TerminalTabID(rawValue: UUID())
    let second = TerminalTabID(rawValue: UUID())
    let other = TerminalTabID(rawValue: UUID())
    let candidates = [
      CanvasCardRef(worktreeID: "other", tabID: other),
      CanvasCardRef(worktreeID: "anchor", tabID: first),
      CanvasCardRef(worktreeID: "anchor", tabID: second),
    ]
    let request = CanvasFocusRequest(id: 1, target: .selectedTabInWorktree("anchor"))

    let selected = CanvasFocusResolver.resolve(
      request: request, candidates: candidates, currentPrimaryTabID: nil, selectedTabID: { _ in second })
    #expect(selected == second)

    let noSelection = CanvasFocusResolver.resolve(
      request: request, candidates: candidates, currentPrimaryTabID: nil, selectedTabID: { _ in nil })
    #expect(noSelection == first)

    let selectedElsewhere = CanvasFocusResolver.resolve(
      request: request, candidates: candidates, currentPrimaryTabID: nil, selectedTabID: { _ in other })
    #expect(selectedElsewhere == first)
  }

  @Test func selectedTabTargetWaitsForTheWorktreeCard() {
    let candidates = [CanvasCardRef(worktreeID: "other", tabID: TerminalTabID(rawValue: UUID()))]
    let request = CanvasFocusRequest(id: 1, target: .selectedTabInWorktree("anchor"))

    #expect(CanvasFocusResolver.resolve(request: request, candidates: candidates, currentPrimaryTabID: nil) == nil)
  }
}
