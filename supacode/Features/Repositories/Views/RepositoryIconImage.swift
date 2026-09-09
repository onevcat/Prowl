import AppKit
import SwiftUI

/// Single source of truth for rendering a `RepositoryIconSource` —
/// shared by the settings preview, the sidebar row, the shelf spine
/// header, and the canvas card title bar so tinting / fallback rules
/// stay consistent in one place.
///
/// Tinting follows `RepositoryIconSource.isTintable`: SF Symbols and
/// SVG user images pick up `tintColor`; PNG user images and bundled
/// assets ignore it. Missing user images fall back to a neutral SF
/// Symbol so a deleted file on disk doesn't turn into a blank slot.
struct RepositoryIconImage: View {
  let icon: RepositoryIconSource
  let repositoryRootURL: URL
  /// Color used for tintable artwork. Pass `nil` to keep the
  /// renderer's natural foreground (`.primary` / template default).
  let tintColor: Color?
  /// Logical pixel size of the icon. Affects `Image` sizing for asset
  /// and user-image cases; SF Symbols size off the surrounding font.
  let size: CGFloat

  init(
    icon: RepositoryIconSource,
    repositoryRootURL: URL,
    tintColor: Color? = nil,
    size: CGFloat = 16
  ) {
    self.icon = icon
    self.repositoryRootURL = repositoryRootURL
    self.tintColor = tintColor
    self.size = size
  }

  var body: some View {
    content
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var content: some View {
    switch icon {
    case .sfSymbol(let name):
      Image(systemName: name)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(resolvedTint)
        .accessibilityHidden(true)
    case .bundledAsset(let assetName):
      Image(assetName)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .accessibilityHidden(true)
    case .userImage(let filename), .detectedImage(let filename):
      userImage(filename: filename)
    }
  }

  @ViewBuilder
  private func userImage(filename: String) -> some View {
    let url = SupacodePaths.repositoryIconFileURL(
      filename: filename, repositoryRootURL: repositoryRootURL
    )
    if let nsImage = Self.loadImage(at: url, asTemplate: icon.isTintable) {
      if icon.isTintable {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .foregroundStyle(resolvedTint)
          .accessibilityHidden(true)
      } else {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .clipShape(.rect(cornerRadius: size * 0.18))
          .accessibilityHidden(true)
      }
    } else {
      // The icon file was renamed/deleted out from under us. Show a
      // muted placeholder rather than an empty rect so the bug is
      // visible.
      Image(systemName: "questionmark.square.dashed")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
  }

  /// Loads an NSImage from disk and optionally flips it into template
  /// mode so SwiftUI's `.foregroundStyle` can recolor it. Pulled out
  /// of the ViewBuilder body so the side-effecting assignment doesn't
  /// trip the builder's "type '()' cannot conform to 'View'" check.
  private static func loadImage(at url: URL, asTemplate: Bool) -> NSImage? {
    guard let image = NSImage(contentsOf: url) else { return nil }
    image.isTemplate = asTemplate
    return image
  }

  private var resolvedTint: AnyShapeStyle {
    if let tintColor {
      AnyShapeStyle(tintColor)
    } else {
      AnyShapeStyle(.primary)
    }
  }
}
