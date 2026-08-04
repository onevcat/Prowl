import AppKit
import SwiftUI

/// Minimum point size enforced on chrome text (sidebar, Active Agents
/// panel, toolbar, tab bar, and their popovers), Safari-style. Injected at
/// the window root from `GlobalSettings.minimumTextSize`; 0 means no floor,
/// so views hosted outside the main window are unaffected.
private struct MinimumInterfaceTextSizeKey: EnvironmentKey {
  static let defaultValue: Double = 0
}

extension EnvironmentValues {
  var minimumInterfaceTextSize: Double {
    get { self[MinimumInterfaceTextSizeKey.self] }
    set { self[MinimumInterfaceTextSizeKey.self] = newValue }
  }
}

extension View {
  /// Semantic text style that honors the minimum text size setting.
  /// When the style already meets the floor this resolves to the plain
  /// semantic font, so default rendering is byte-identical to `.font(style)`.
  func interfaceFont(
    _ style: Font.TextStyle,
    weight: Font.Weight? = nil,
    design: Font.Design? = nil
  ) -> some View {
    modifier(InterfaceFontModifier(style: style, weight: weight, design: design))
  }
}

private struct InterfaceFontModifier: ViewModifier {
  @Environment(\.minimumInterfaceTextSize) private var minimumSize
  let style: Font.TextStyle
  let weight: Font.Weight?
  let design: Font.Design?

  func body(content: Content) -> some View {
    content.font(
      InterfaceTextMetrics.font(style, weight: weight, design: design, minimumSize: minimumSize)
    )
  }
}

enum InterfaceTextMetrics {
  static func font(
    _ style: Font.TextStyle,
    weight: Font.Weight? = nil,
    design: Font.Design? = nil,
    minimumSize: Double
  ) -> Font {
    var font: Font =
      if minimumSize <= basePointSize(style) {
        .system(style, design: design ?? .default)
      } else {
        .system(size: minimumSize, design: design ?? .default)
      }
    if let weight {
      font = font.weight(weight)
    }
    return font
  }

  static func pointSize(_ style: Font.TextStyle, minimumSize: Double) -> Double {
    max(basePointSize(style), minimumSize)
  }

  /// Points the floor adds to a style (0 when the style already meets it).
  /// Row heights sized for one line of that style grow by this amount.
  static func extraHeight(_ style: Font.TextStyle, minimumSize: Double) -> CGFloat {
    CGFloat(pointSize(style, minimumSize: minimumSize) - basePointSize(style))
  }

  /// Resolved size relative to the system size, for lengths that must track
  /// a style proportionally (for example the checks ring beside caption text).
  static func scaleFactor(_ style: Font.TextStyle, minimumSize: Double) -> Double {
    pointSize(style, minimumSize: minimumSize) / basePointSize(style)
  }

  /// Ascender of the system font rows use for their primary text, at the
  /// given floor. Keeps AppKit-derived baseline alignment guides in step
  /// with the resolved SwiftUI fonts.
  static func bodyAscender(minimumSize: Double) -> CGFloat {
    NSFont.systemFont(ofSize: pointSize(.body, minimumSize: minimumSize)).ascender
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
    case .callout:
      return .callout
    case .footnote:
      return .footnote
    case .caption:
      return .caption1
    case .caption2:
      return .caption2
    default:
      return .body
    }
  }
}
