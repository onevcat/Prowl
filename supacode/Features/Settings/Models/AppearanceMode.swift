import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
  case system
  case light
  case dark

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .system:
      return "System"
    case .light:
      return "Light"
    case .dark:
      return "Dark"
    }
  }

  var colorScheme: ColorScheme {
    switch self {
    case .system:
      let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      return isDark ? .dark : .light
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }

  var previewBackground: Color {
    switch self {
    case .system:
      return Color(nsColor: .windowBackgroundColor)
    case .light:
      return .white
    case .dark:
      return .black
    }
  }

  var previewPrimary: Color {
    switch self {
    case .system:
      return .primary.opacity(0.2)
    case .light:
      return .black.opacity(0.15)
    case .dark:
      return .white.opacity(0.2)
    }
  }

  var previewSecondary: Color {
    switch self {
    case .system:
      return .primary.opacity(0.12)
    case .light:
      return .black.opacity(0.08)
    case .dark:
      return .white.opacity(0.12)
    }
  }

  var previewAccent: Color {
    .blue
  }

}
