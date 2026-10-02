import AppKit
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct TerminalTabBarColorsTests {
  @Test
  func adaptiveFillsResolveOffMainThread() async {
    for color in [
      TerminalTabBarColors.barBackground,
      TerminalTabBarColors.activeTabBackground,
      TerminalTabBarColors.hoveredTabBackground,
    ] {
      let resolved = await resolveOffMain(color)
      #expect(resolved)
    }
  }

  private func resolveOffMain(_ color: Color) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: NSColor(color).usingColorSpace(.sRGB) != nil)
      }
    }
  }
}
