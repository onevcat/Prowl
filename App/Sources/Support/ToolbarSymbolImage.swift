import AppKit
import SwiftUI

/// SF Symbols for the window toolbar, from cached `NSImage`s.
///
/// SwiftUI keeps a menu form of every toolbar item, and resolves an `Image(systemName:)` in it
/// again through the asset catalog, with a locale match, each time the window environment
/// changes. That happens several times per worktree switch, for every toolbar symbol (about
/// 15 ms per switch). An `NSImage` needs no lookup.
///
/// An `NSImage` does not follow the SwiftUI font, so the caller gives the text style, weight,
/// and scale that the symbol had: toolbar controls use `.body` at `.large` scale.
@MainActor
enum ToolbarSymbolImage {
  private struct Key: Hashable {
    let name: String
    let textStyle: NSFont.TextStyle
    let weight: NSFont.Weight
    let scale: NSImage.SymbolScale
  }

  private static var images: [Key: NSImage] = [:]

  static func image(
    _ systemName: String,
    textStyle: NSFont.TextStyle = .body,
    weight: NSFont.Weight = .regular,
    scale: NSImage.SymbolScale = .large
  ) -> Image {
    Image(nsImage: nsImage(systemName, textStyle: textStyle, weight: weight, scale: scale))
  }

  static func nsImage(
    _ systemName: String,
    textStyle: NSFont.TextStyle = .body,
    weight: NSFont.Weight = .regular,
    scale: NSImage.SymbolScale = .large
  ) -> NSImage {
    let key = Key(name: systemName, textStyle: textStyle, weight: weight, scale: scale)
    if let image = images[key] {
      return image
    }
    let configuration = NSImage.SymbolConfiguration(
      pointSize: NSFont.preferredFont(forTextStyle: textStyle).pointSize,
      weight: weight,
      scale: scale
    )
    let image =
      NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration) ?? NSImage()
    images[key] = image
    return image
  }
}
