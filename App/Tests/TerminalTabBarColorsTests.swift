import AppKit
import SwiftUI
import Synchronization
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

  // The fills must be built under the appearance being resolved, not the one current when the
  // `Color` was created: `withAlphaComponent` freezes a dynamic system color, so a fill built
  // eagerly would render the other half of the brightness ladder.
  @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
  func adaptiveFillsMatchTheResolvedAppearanceOnAnyThread(_ appearanceName: NSAppearance.Name) async {
    for fill in AdaptiveFill.allCases {
      let color = NSColor(fill.color)
      let expected = Self.resolve({ fill.reference(darkAqua: appearanceName == .darkAqua) }, in: appearanceName)
      let onMain = Self.resolve({ color }, in: appearanceName)
      let offMain: RGBA? = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          continuation.resume(returning: Self.resolve({ color }, in: appearanceName))
        }
      }
      #expect(expected != nil)
      #expect(onMain == expected, "\(fill) on the main thread under \(appearanceName.rawValue)")
      #expect(offMain == expected, "\(fill) off the main thread under \(appearanceName.rawValue)")
    }
  }

  // Render threads of different windows can resolve the same fill at once under different
  // appearances. The drawing appearance is per thread, so no result may take the other's.
  @Test
  func adaptiveFillsResolveConcurrentlyUnderMixedAppearances() async {
    let appearanceNames: [NSAppearance.Name] = [.aqua, .darkAqua]
    let cases = AdaptiveFill.allCases.flatMap { fill in
      appearanceNames.map { name in
        ResolutionCase(
          fill: fill,
          color: NSColor(fill.color),
          appearanceName: name,
          expected: Self.resolve({ fill.reference(darkAqua: name == .darkAqua) }, in: name)
        )
      }
    }
    let mismatches: [String] = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        let mismatches = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: cases.count * 50) { index in
          let resolutionCase = cases[index % cases.count]
          let resolved = Self.resolve({ resolutionCase.color }, in: resolutionCase.appearanceName)
          if resolved == nil || resolved != resolutionCase.expected {
            mismatches.withLock { $0.append("\(resolutionCase.fill) under \(resolutionCase.appearanceName.rawValue)") }
          }
        }
        continuation.resume(returning: mismatches.withLock { $0 })
      }
    }
    #expect(mismatches.isEmpty)
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

  // The brightness ladder spelled out independently of `TerminalTabBarColors`.
  nonisolated func reference(darkAqua: Bool) -> NSColor {
    switch (self, darkAqua) {
    case (.bar, true): .labelColor.withAlphaComponent(0.10)
    case (.bar, false): .labelColor.withAlphaComponent(0.08)
    case (.activeTab, true): .labelColor.withAlphaComponent(0.25)
    case (.activeTab, false): .controlBackgroundColor
    case (.hoveredTab, true): .labelColor.withAlphaComponent(0.08)
    case (.hoveredTab, false): .controlBackgroundColor.withAlphaComponent(0.5)
    }
  }
}

private nonisolated struct ResolutionCase: Sendable {
  let fill: AdaptiveFill
  let color: NSColor
  let appearanceName: NSAppearance.Name
  let expected: RGBA?
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
