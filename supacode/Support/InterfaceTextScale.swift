import AppKit
import SwiftUI

/// Multiplier applied to chrome text (sidebar, Active Agents panel).
/// Injected at the window root from `GlobalSettings.interfaceTextSize`;
/// defaults to 1 so views hosted outside the main window are unaffected.
private struct InterfaceTextScaleKey: EnvironmentKey {
  static let defaultValue: Double = 1
}

extension EnvironmentValues {
  var interfaceTextScale: Double {
    get { self[InterfaceTextScaleKey.self] }
    set { self[InterfaceTextScaleKey.self] = newValue }
  }
}

extension View {
  /// Semantic text style that follows the interface text size setting.
  /// At the default scale this resolves to the plain semantic font, so
  /// unscaled rendering is byte-identical to `.font(style)`.
  func interfaceFont(
    _ style: Font.TextStyle,
    weight: Font.Weight? = nil,
    design: Font.Design? = nil
  ) -> some View {
    modifier(InterfaceFontModifier(style: style, weight: weight, design: design))
  }
}

private struct InterfaceFontModifier: ViewModifier {
  @Environment(\.interfaceTextScale) private var scale
  let style: Font.TextStyle
  let weight: Font.Weight?
  let design: Font.Design?

  func body(content: Content) -> some View {
    content.font(InterfaceTextMetrics.font(style, weight: weight, design: design, scale: scale))
  }
}

enum InterfaceTextMetrics {
  static func font(
    _ style: Font.TextStyle,
    weight: Font.Weight? = nil,
    design: Font.Design? = nil,
    scale: Double
  ) -> Font {
    var font: Font =
      if scale == 1 {
        .system(style, design: design ?? .default)
      } else {
        .system(size: pointSize(style, scale: scale), design: design ?? .default)
      }
    if let weight {
      font = font.weight(weight)
    }
    return font
  }

  static func pointSize(_ style: Font.TextStyle, scale: Double) -> Double {
    NSFont.preferredFont(forTextStyle: nsTextStyle(style)).pointSize * scale
  }

  /// Ascender of the system font rows use for their primary text, at the
  /// given scale. Keeps AppKit-derived baseline alignment guides in step
  /// with the scaled SwiftUI fonts.
  static func bodyAscender(scale: Double) -> CGFloat {
    NSFont.systemFont(ofSize: pointSize(.body, scale: scale)).ascender
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
