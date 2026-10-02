import Foundation
import Testing

@testable import supacode

struct CanvasFocusResolverTests {
  @Test func worktreeTargetSelectsFirstCardWhenNothingIsFocused() {
    let worktreeID = "/tmp/repo/main"
    let first = TerminalTabID(rawValue: UUID())
    let second = TerminalTabID(rawValue: UUID())

    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .worktree(worktreeID)),
      candidates: [
        CanvasFocusCandidate(worktreeID: worktreeID, tabID: first),
        CanvasFocusCandidate(worktreeID: worktreeID, tabID: second),
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
        CanvasFocusCandidate(worktreeID: worktreeID, tabID: first),
        CanvasFocusCandidate(worktreeID: "/tmp/other/main", tabID: other),
        CanvasFocusCandidate(worktreeID: worktreeID, tabID: second),
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
        CanvasFocusCandidate(worktreeID: worktreeID, tabID: first),
        CanvasFocusCandidate(worktreeID: worktreeID, tabID: second),
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
        CanvasFocusCandidate(worktreeID: "/tmp/repo/main", tabID: TerminalTabID(rawValue: UUID())),
        CanvasFocusCandidate(worktreeID: "/tmp/repo/main", tabID: requested),
      ],
      currentPrimaryTabID: nil
    )

    #expect(resolved == requested)
  }

  @Test func tabTargetWaitsWhenExactCardIsNotVisibleYet() {
    let resolved = CanvasFocusResolver.resolve(
      request: CanvasFocusRequest(id: 1, target: .tab(TerminalTabID(rawValue: UUID()))),
      candidates: [
        CanvasFocusCandidate(worktreeID: "/tmp/repo/main", tabID: TerminalTabID(rawValue: UUID()))
      ],
      currentPrimaryTabID: nil
    )

    #expect(resolved == nil)
  }
}
