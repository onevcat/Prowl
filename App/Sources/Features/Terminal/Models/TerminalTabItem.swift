import Foundation
import ProwlCLIShared

/// Who currently owns a tab's icon slot. The precedence chain runs
/// `auto < script < user`: stronger owners block weaker writes.
///
/// - `auto`: nobody has claimed the icon — `CommandIconMap` and other
///   auto-detection paths are free to overwrite it.
/// - `script`: Run Script's `play.fill` or a Custom Command's configured
///   icon. Survives auto-detection so the glyph doesn't flash mid-run.
/// - `user`: the icon picker. Wins over everything until cleared.
///
/// Avoid naming a case `.none` — it collides with `Optional.none` in
/// expressions like `tab?.iconLock == .none`, where Swift would infer
/// the right-hand side as the optional sentinel rather than this case.
enum TerminalTabIconLock: Equatable, Sendable {
  case auto
  case script
  case user
}

struct TerminalTabItem: Identifiable, Equatable, Sendable {
  let id: TerminalTabID
  var title: String
  var customTitle: String?
  var icon: String?
  var isDirty: Bool
  var isTitleLocked: Bool
  var iconLock: TerminalTabIconLock

  var displayTitle: String { customTitle ?? title }

  init(
    id: TerminalTabID = TerminalTabID(),
    title: String,
    customTitle: String? = nil,
    icon: String?,
    isDirty: Bool = false,
    isTitleLocked: Bool = false,
    iconLock: TerminalTabIconLock = .auto
  ) {
    self.id = id
    self.title = title
    self.customTitle = customTitle
    self.icon = icon
    self.isDirty = isDirty
    self.isTitleLocked = isTitleLocked
    self.iconLock = iconLock
  }
}
