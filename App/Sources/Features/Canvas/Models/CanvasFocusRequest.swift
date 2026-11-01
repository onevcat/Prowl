import Foundation
import ProwlCLIShared

struct CanvasFocusRequest: Equatable, Sendable {
  enum Target: Equatable, Sendable {
    case worktree(Worktree.ID)
    case tab(TerminalTabID)
    /// The tab that the worktree has selected, as Normal view would show it.
    case selectedTabInWorktree(Worktree.ID)
  }

  /// How the viewport follows the focused card.
  enum Viewport: Equatable, Sendable {
    /// Center and zoom to the card — explicit navigation to it.
    case center
    /// Show the card with the least pan (zooming out only if it does not fit),
    /// keeping the surrounding cards in view — used for newly created cards.
    case reveal
  }

  let id: Int
  let target: Target
  var viewport: Viewport = .center
}

/// One card on the canvas: an open tab that has a surface, plus the worktree
/// that owns it.
struct CanvasCardRef: Equatable, Sendable {
  let worktreeID: Worktree.ID
  let tabID: TerminalTabID

  var key: String { tabID.canvasCardKey }
}

extension TerminalTabID {
  /// Key of this tab's card in `CanvasLayoutStore` (persisted, so it must stay
  /// the tab UUID string).
  var canvasCardKey: String { rawValue.uuidString }
}

/// A reducer-driven request to run one of CanvasView's view-local commands
/// (which live in CanvasView's `@State`, not the reducer) — e.g. triggered from
/// the command palette. CanvasView observes it, runs the command, and reports
/// the id back to clear it (the same one-shot pattern as `CanvasFocusRequest`).
struct CanvasCommandRequest: Equatable, Sendable {
  enum Command: Equatable, Sendable {
    case toggleExpand
    case layout(CanvasLayoutKind)
    case fit
    case selectAll
    case navigate(CanvasNavigationDirection)
  }

  let id: Int
  let command: Command
}

enum CanvasFocusResolver {
  static func resolve(
    request: CanvasFocusRequest,
    candidates: [CanvasCardRef],
    currentPrimaryTabID: TerminalTabID?,
    selectedTabID: (Worktree.ID) -> TerminalTabID? = { _ in nil }
  ) -> TerminalTabID? {
    switch request.target {
    case .selectedTabInWorktree(let worktreeID):
      let matchingTabIDs = candidates.filter { $0.worktreeID == worktreeID }.map(\.tabID)
      if let selected = selectedTabID(worktreeID), matchingTabIDs.contains(selected) {
        return selected
      }
      return matchingTabIDs.first

    case .tab(let tabID):
      return candidates.contains { $0.tabID == tabID } ? tabID : nil

    case .worktree(let worktreeID):
      let matchingTabIDs = candidates.compactMap { candidate in
        candidate.worktreeID == worktreeID ? candidate.tabID : nil
      }
      guard !matchingTabIDs.isEmpty else { return nil }
      guard let currentPrimaryTabID,
        let currentIndex = matchingTabIDs.firstIndex(of: currentPrimaryTabID)
      else {
        return matchingTabIDs[0]
      }
      return matchingTabIDs[(currentIndex + 1) % matchingTabIDs.count]
    }
  }
}

/// Which newly placed card Canvas follows.
enum CanvasNewCardFocus {
  /// The last new card, in canvas order, whose tab was created in the
  /// foreground. Background creations, restores, and existing cards that only
  /// just appeared on the canvas are never followed.
  static func cardToFollow(
    newKeys: Set<String>,
    cards: [CanvasCardRef],
    foregroundTabIDs: Set<TerminalTabID>
  ) -> CanvasCardRef? {
    cards.last { newKeys.contains($0.key) && foregroundTabIDs.contains($0.tabID) }
  }
}
