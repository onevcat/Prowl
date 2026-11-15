import Foundation

/// The automatic layouts Canvas can apply to every card at once. Each one is
/// reachable from the canvas toolbar, its keyboard shortcut, and the command
/// palette, and all of them funnel into `CanvasView.applyLayout(_:)`.
///
/// - `arrange`: bin-pack the cards, preserving each card's size.
/// - `organize`: reset every card to the default size in a √N grid.
/// - `tile`: resize every card so the set tiles and fills the viewport.
enum CanvasLayoutKind: String, CaseIterable, Sendable {
  case arrange
  case organize
  case tile

  /// The keybinding that triggers this layout. These IDs are persisted in
  /// user keybinding overrides, so they never change.
  var commandID: String {
    switch self {
    case .arrange: AppShortcuts.CommandID.arrangeCanvasCards
    case .organize: AppShortcuts.CommandID.organizeCanvasCards
    case .tile: AppShortcuts.CommandID.tileCanvasCards
    }
  }

  /// The app-default shortcut, used as the key-press fallback when the
  /// resolved binding is unavailable.
  var defaultShortcut: AppShortcut {
    switch self {
    case .arrange: AppShortcuts.arrangeCanvasCards
    case .organize: AppShortcuts.organizeCanvasCards
    case .tile: AppShortcuts.tileCanvasCards
    }
  }

  var systemImage: String {
    switch self {
    case .arrange: "rectangle.3.group"
    case .organize: "square.grid.2x2"
    case .tile: "rectangle.split.2x1"
    }
  }

  /// Short name of the layout, used as the toolbar button's accessibility label.
  var title: LocalizedStringResource {
    switch self {
    case .arrange: "Arrange"
    case .organize: "Organize"
    case .tile: "Tile"
    }
  }

  /// One-line description used as the toolbar button tooltip.
  var helpTitle: String.LocalizationValue {
    switch self {
    case .arrange: "Arrange cards preserving sizes"
    case .organize: "Organize cards in a uniform grid"
    case .tile: "Tile cards to fill the canvas"
    }
  }

  /// Tooltip while this layout is the active automatic mode.
  var activeHelpTitle: String.LocalizationValue {
    switch self {
    case .arrange: "Arranging: cards re-arrange as they are added or closed"
    case .organize: "Organizing: cards keep the grid as they are added or closed"
    case .tile: "Tiling: cards re-tile as they are added or closed"
    }
  }
}
