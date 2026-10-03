import Foundation

/// Specifies the artwork to use for a tab icon. `systemSymbol` is an
/// always-available SF Symbol fallback; `assetName` is an optional,
/// more specific PNG/SVG shipped in the asset catalog (used for
/// branded CLI tools like docker/git/claude where stock SF Symbols
/// don't read well).
///
/// Renderers prefer `assetName` when present, falling back to
/// `systemSymbol` when the asset is missing or asset rendering isn't
/// yet wired into a particular call site.
struct TabIconSource: Equatable, Hashable, Sendable {
  /// SF Symbol drawn via `Image(systemName:)`.
  let systemSymbol: String
  /// Asset catalog entry. When set, renderers paint `Image(_:)` for
  /// this name and ignore `systemSymbol`; when missing, they fall
  /// back to the SF Symbol.
  let assetName: String?

  init(systemSymbol: String, assetName: String? = nil) {
    self.systemSymbol = systemSymbol
    self.assetName = assetName
  }

  /// Serialised form stored in `TerminalTabItem.icon`. SF Symbols are
  /// stored bare (so existing `tab.icon = "terminal"` keeps working
  /// for the user-icon-picker path); assets carry a marker so the
  /// renderer can switch APIs.
  var storageString: String {
    if let assetName {
      return ResolvedTabIcon.assetMarker + assetName
    }
    return systemSymbol
  }
}

/// What `TerminalTabItem.icon` resolves to once parsed by the
/// renderer. Built from a stored string via `parse(_:)` — the inverse
/// of `TabIconSource.storageString`. Lives next to `TabIconSource`
/// because the two share the marker convention.
enum ResolvedTabIcon: Equatable, Hashable, Sendable {
  case systemSymbol(String)
  case asset(name: String)

  static let assetMarker = "@asset:"

  static func parse(_ raw: String) -> ResolvedTabIcon {
    if raw.hasPrefix(assetMarker) {
      return .asset(name: String(raw.dropFirst(assetMarker.count)))
    }
    return .systemSymbol(raw)
  }
}
