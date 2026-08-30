import AppKit
import SwiftUI

/// How text in the app resolves: a proportional scale applied to every style,
/// then a hard floor under the result.
///
/// The two are separate because neither can do the other's job. A floor lifts
/// everything below it to exactly itself, so it compresses: at 16pt, caption
/// through headline all resolve to 16 and stop being distinguishable. That is
/// correct for an accessibility floor and wrong for "make the interface
/// bigger", which has to keep the ramp intact. Scaling keeps it intact and
/// guarantees no lower bound. A reader who wants both sets both.
///
/// Terminal content is excluded: its size comes from the Ghostty font settings.
struct InterfaceTextResolution: Equatable, Sendable {
  /// Multiplier on every style's system size. 1 leaves sizes alone.
  var scale: Double = 1
  /// Hard lower bound in points, applied after scaling. 0 means no floor.
  var minimumSize: Double = 0

  static let system = InterfaceTextResolution()
}

/// Injected at the window root from `GlobalSettings`. The default leaves every
/// size at the system value, so views hosted outside the main window and
/// previews render exactly as they would without the feature.
private struct InterfaceTextResolutionKey: EnvironmentKey {
  static let defaultValue = InterfaceTextResolution.system
}

extension EnvironmentValues {
  var interfaceText: InterfaceTextResolution {
    get { self[InterfaceTextResolutionKey.self] }
    set { self[InterfaceTextResolutionKey.self] = newValue }
  }
}

extension View {
  /// Semantic text style that honours the interface text settings. When both
  /// settings are at their defaults this resolves to the plain semantic font,
  /// so default rendering is identical to `.font(style)`.
  func interfaceFont(
    _ style: Font.TextStyle,
    weight: Font.Weight? = nil,
    design: Font.Design? = nil
  ) -> some View {
    modifier(InterfaceFontModifier(style: style, weight: weight, design: design))
  }

  /// Reading text whose size was written as a point value rather than a
  /// semantic style. It scales with the settings like any other text; only the
  /// starting size is spelled out. Prefer a semantic style where one fits, so
  /// the ramp stays the single source of relative sizing.
  func interfaceFont(
    size: Double,
    weight: Font.Weight? = nil,
    design: Font.Design? = nil
  ) -> some View {
    modifier(InterfaceSizedFontModifier(size: size, weight: weight, design: design))
  }

  /// Text or a symbol whose size is deliberately fixed, exempt from the
  /// interface text settings. Use it where a point size is a layout constant
  /// rather than a reading size — an SF Symbol sized to a fixed slot, a glyph
  /// aligned to a drawn shape. Naming the exemption keeps it greppable and
  /// reviewable, which a bare `.font(...)` does not.
  func fixedInterfaceFont(_ font: Font) -> some View {
    self.font(font)
  }
}

private struct InterfaceFontModifier: ViewModifier {
  @Environment(\.interfaceText) private var resolution
  let style: Font.TextStyle
  let weight: Font.Weight?
  let design: Font.Design?

  func body(content: Content) -> some View {
    content.font(
      InterfaceTextMetrics.font(style, weight: weight, design: design, resolution: resolution)
    )
  }
}

extension Text {
  /// Resolved style for a value that has to stay a `Text`. String
  /// interpolation composes `Text`, so a title assembled from several styled
  /// pieces cannot go through the `View` modifiers, which return `some View`.
  ///
  /// The resolution is passed in because a `Text`-typed property cannot read
  /// the environment. Read it once in the enclosing view and hand it down.
  func interfaceFont(
    _ style: Font.TextStyle,
    weight: Font.Weight? = nil,
    design: Font.Design? = nil,
    resolution: InterfaceTextResolution
  ) -> Text {
    font(InterfaceTextMetrics.font(style, weight: weight, design: design, resolution: resolution))
  }
}

private struct InterfaceSizedFontModifier: ViewModifier {
  @Environment(\.interfaceText) private var resolution
  let size: Double
  let weight: Font.Weight?
  let design: Font.Design?

  func body(content: Content) -> some View {
    var font = Font.system(
      size: InterfaceTextMetrics.pointSize(size, resolution: resolution),
      design: design ?? .default
    )
    if let weight {
      font = font.weight(weight)
    }
    return content.font(font)
  }
}

enum InterfaceTextMetrics {
  static func font(
    _ style: Font.TextStyle,
    weight: Font.Weight? = nil,
    design: Font.Design? = nil,
    resolution: InterfaceTextResolution
  ) -> Font {
    let base = basePointSize(style)
    let resolved = pointSize(style, resolution: resolution)
    var font: Font =
      if resolved == base {
        .system(style, design: design ?? .default)
      } else {
        .system(size: resolved, design: design ?? .default)
      }
    if let weight {
      font = font.weight(weight)
    }
    return font
  }

  /// Scale first, then floor. The order matters: flooring first would let the
  /// scale lift text back above a floor the reader set as a lower bound, which
  /// is harmless, and would also let it drag text below one, which is not.
  static func pointSize(_ style: Font.TextStyle, resolution: InterfaceTextResolution) -> Double {
    max(basePointSize(style) * resolution.scale, resolution.minimumSize)
  }

  /// Same rule for a raw point size that carries no semantic style, for the
  /// places that hand a size to AppKit rather than resolving a `Font`.
  static func pointSize(_ base: Double, resolution: InterfaceTextResolution) -> Double {
    max(base * resolution.scale, resolution.minimumSize)
  }

  /// Points the settings add to a style (0 when nothing applies).
  /// Row heights sized for one line of that style grow by this amount.
  static func extraHeight(_ style: Font.TextStyle, resolution: InterfaceTextResolution) -> CGFloat {
    CGFloat(pointSize(style, resolution: resolution) - basePointSize(style))
  }

  /// Resolved size relative to the system size, for lengths that must track
  /// a style proportionally (for example the checks ring beside caption text).
  static func scaleFactor(_ style: Font.TextStyle, resolution: InterfaceTextResolution) -> Double {
    pointSize(style, resolution: resolution) / basePointSize(style)
  }

  /// Ascender of the system font rows use for their primary text, at the
  /// resolved size. Keeps AppKit-derived baseline alignment guides in step
  /// with the resolved SwiftUI fonts.
  static func bodyAscender(resolution: InterfaceTextResolution) -> CGFloat {
    NSFont.systemFont(ofSize: pointSize(.body, resolution: resolution)).ascender
  }

  private static func basePointSize(_ style: Font.TextStyle) -> Double {
    NSFont.preferredFont(forTextStyle: nsTextStyle(style)).pointSize
  }

  private static func nsTextStyle(_ style: Font.TextStyle) -> NSFont.TextStyle {
    switch style {
    case .largeTitle:
      return .largeTitle
    case .title:
      return .title1
    case .title2:
      return .title2
    case .title3:
      return .title3
    case .headline:
      return .headline
    case .subheadline:
      return .subheadline
    case .body:
      return .body
    case .callout:
      return .callout
    case .footnote:
      return .footnote
    case .caption:
      return .caption1
    case .caption2:
      return .caption2
    @unknown default:
      return .body
    }
  }
}
