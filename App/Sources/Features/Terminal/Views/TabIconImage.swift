import SwiftUI

/// Renders the icon for a `TerminalTabItem`. Decodes the storage
/// string via `ResolvedTabIcon` and dispatches to either
/// `Image(systemName:)` (SF Symbol) or `Image(_:)` (asset catalog).
/// Both branches honour the surrounding `foregroundStyle` because
/// asset entries ship as template SVGs (`@asset:` marker — see
/// `TabIconSource.storageString` and `Assets.xcassets/CommandIcons`).
///
/// `pointSize` is the on-screen size both branches target: the SF
/// Symbol path uses `.font(.system(size:))` so the symbol scales
/// with the value; the asset path uses `.resizable() + frame` for
/// the same final footprint. Keeping both branches at the same
/// nominal size avoids visual jumps when a tab switches between an
/// SF Symbol fallback and a branded asset.
struct TabIconImage: View {
  let rawName: String
  let pointSize: CGFloat

  var body: some View {
    Group {
      switch ResolvedTabIcon.parse(rawName) {
      case .systemSymbol(let name):
        Image(systemName: name)
          .font(.system(size: pointSize))
      case .asset(let name):
        Image(name)
          .resizable()
          .scaledToFit()
          .frame(width: pointSize, height: pointSize)
      }
    }
    // Tab icons are decorative — `tab.title` already provides the
    // accessible label for the tab. Callers that need a custom label
    // can override after construction.
    .accessibilityHidden(true)
  }
}
