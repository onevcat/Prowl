enum CanvasInteractionPolicy {
  static func linkActivationRequested(
    hasHoveredLink: Bool,
    isCommandModifierActive: Bool
  ) -> Bool {
    hasHoveredLink && isCommandModifierActive
  }

  /// Whether any terminal pane of a card that is actually on screen currently
  /// has a hovered link. Only `visibleLeaves()` are scanned: a pane hidden by
  /// split zoom can otherwise retain a stale `mouseOverLink` and incorrectly
  /// disable the selection shield for the visible pane.
  static func hasHoveredLink(in tree: SplitTree<GhosttySurfaceView>) -> Bool {
    tree.visibleLeaves().contains {
      $0.bridge.state.mouseOverLink?.isEmpty == false
    }
  }

  static func showsSelectionShield(
    commandSelectionActive: Bool,
    selectionModeActive: Bool,
    broadcastFollower: Bool,
    linkActivationRequested: Bool
  ) -> Bool {
    if linkActivationRequested {
      return false
    }
    if commandSelectionActive || selectionModeActive {
      return true
    }
    return broadcastFollower
  }

  /// Whether a card's terminal surface should receive mouse events. Focused
  /// cards are always interactive; for every other card (e.g. broadcast
  /// followers) a link activation is the only interaction allowed through —
  /// anything else must keep routing to the selection callbacks.
  static func terminalHitTestingEnabled(
    isFocused: Bool,
    linkActivationRequested: Bool,
    showsSelectionShield: Bool
  ) -> Bool {
    (isFocused || linkActivationRequested) && !showsSelectionShield
  }
}
