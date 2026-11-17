import AppKit
import SwiftUI
import Testing

@testable import Prowl

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

  // #1124: SwiftUI's async renderer resolves these fills on its display-link thread while it
  // holds the view graph lock, and the main thread can be waiting for that same lock (AppKit
  // invalidates hosting views when the app deactivates). Resolution must not need the main thread.
  @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
  func adaptiveFillsResolveWhileMainThreadWaitsForRenderThread(_ appearanceName: NSAppearance.Name) async {
    for fill in AdaptiveFill.allCases {
      let color = NSColor(fill.color)
      let viewGraphLock = NSLock()
      let renderThreadHoldsLock = DispatchSemaphore(value: 0)
      var mainThreadAcquiredLock = false
      let resolved: RGBA? = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          viewGraphLock.lock()
          renderThreadHoldsLock.signal()
          let resolved = Self.resolve({ color }, in: appearanceName)
          viewGraphLock.unlock()
          continuation.resume(returning: resolved)
        }
        // Still synchronous on the main thread: block on the render thread's lock, as
        // `_MovableLockLock` does, so the main queue cannot drain until the lock is released.
        guard renderThreadHoldsLock.wait(timeout: .now() + Self.deadlockTimeout) == .success else { return }
        mainThreadAcquiredLock = viewGraphLock.lock(before: Date(timeIntervalSinceNow: Self.deadlockTimeout))
        if mainThreadAcquiredLock {
          viewGraphLock.unlock()
        }
      }
      #expect(mainThreadAcquiredLock, "\(fill) deadlocked resolving under \(appearanceName.rawValue)")
      #expect(resolved != nil)
    }
  }

  private static let deadlockTimeout: TimeInterval = 5

  private func resolveOffMain(_ color: Color) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: NSColor(color).usingColorSpace(.sRGB) != nil)
      }
    }
  }

  private nonisolated static func resolve(
    _ makeColor: () -> NSColor,
    in appearanceName: NSAppearance.Name
  ) -> RGBA? {
    var resolved: RGBA?
    NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
      resolved = makeColor().usingColorSpace(.sRGB).map(RGBA.init)
    }
    return resolved
  }
}

private enum AdaptiveFill: CaseIterable {
  case bar
  case activeTab
  case hoveredTab

  var color: Color {
    switch self {
    case .bar: TerminalTabBarColors.barBackground
    case .activeTab: TerminalTabBarColors.activeTabBackground
    case .hoveredTab: TerminalTabBarColors.hoveredTabBackground
    }
  }
}

private nonisolated struct RGBA: Equatable, Sendable {
  let red: CGFloat
  let green: CGFloat
  let blue: CGFloat
  let alpha: CGFloat

  init(_ color: NSColor) {
    red = color.redComponent
    green = color.greenComponent
    blue = color.blueComponent
    alpha = color.alphaComponent
  }
}
