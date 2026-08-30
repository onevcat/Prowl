import AppKit
import SwiftUI
import Testing

@testable import supacode

/// The two interface text settings resolve differently on purpose, and the
/// difference is the reason there are two of them. These pin that difference.
struct InterfaceTextMetricsTests {
  /// The styles the app chrome actually uses, smallest first.
  private static let ramp: [Font.TextStyle] = [
    .caption2, .caption, .footnote, .subheadline, .callout, .body, .headline, .title3, .title2,
  ]

  private func base(_ style: Font.TextStyle) -> Double {
    InterfaceTextMetrics.pointSize(style, resolution: .system)
  }

  @Test func defaultsLeaveEverySizeAtTheSystemValue() {
    for style in Self.ramp {
      let resolved = InterfaceTextMetrics.pointSize(style, resolution: .system)
      #expect(resolved == base(style), "\(style) moved with no setting applied")
      #expect(InterfaceTextMetrics.extraHeight(style, resolution: .system) == 0)
      #expect(InterfaceTextMetrics.scaleFactor(style, resolution: .system) == 1)
    }
  }

  @Test func floorLiftsOnlyStylesBelowIt() {
    let resolution = InterfaceTextResolution(scale: 1, minimumSize: 12)
    for style in Self.ramp {
      let resolved = InterfaceTextMetrics.pointSize(style, resolution: resolution)
      if base(style) >= 12 {
        #expect(resolved == base(style), "\(style) was already above the floor and moved")
      } else {
        #expect(resolved == 12, "\(style) was below the floor and did not reach it")
      }
    }
  }

  /// A floor collapses everything under it onto one size. This is inherent to a
  /// floor rather than a defect, and it is why the scale setting exists: a
  /// reader who wants larger text with the hierarchy intact must not be told to
  /// reach for this one.
  @Test func floorCollapsesTheStylesBeneathIt() {
    let resolution = InterfaceTextResolution(scale: 1, minimumSize: 16)
    let collapsed = Self.ramp.filter { base($0) < 16 }
    let resolved = Set(collapsed.map { InterfaceTextMetrics.pointSize($0, resolution: resolution) })

    #expect(collapsed.count > 1, "expected several styles below a 16pt floor")
    #expect(resolved == [16], "styles below the floor must all resolve to it")
  }

  @Test func scalePreservesTheOrderingAndTheGaps() {
    let resolution = InterfaceTextResolution(scale: 1.5, minimumSize: 0)
    let resolved = Self.ramp.map { InterfaceTextMetrics.pointSize($0, resolution: resolution) }

    #expect(resolved == Self.ramp.map { base($0) * 1.5 })
    #expect(resolved == resolved.sorted(), "scaling must not reorder the ramp")
    #expect(Set(resolved).count == Set(Self.ramp.map { base($0) }).count, "scaling must not merge sizes")
  }

  @Test func scaleAppliesBeforeTheFloor() {
    // caption scaled past the floor keeps its scaled size rather than being
    // pinned to the floor; a floor applied first would have clamped it low.
    let resolution = InterfaceTextResolution(scale: 2, minimumSize: 12)
    let resolved = InterfaceTextMetrics.pointSize(.caption, resolution: resolution)

    #expect(resolved == base(.caption) * 2)
    #expect(resolved > 12)
  }

  @Test func floorStillAppliesUnderneathASmallScale() {
    let resolution = InterfaceTextResolution(scale: 0.5, minimumSize: 13)
    for style in Self.ramp {
      #expect(InterfaceTextMetrics.pointSize(style, resolution: resolution) >= 13)
    }
  }

  @Test func rawPointSizesFollowTheSameRule() {
    let resolution = InterfaceTextResolution(scale: 1.25, minimumSize: 14)
    #expect(InterfaceTextMetrics.pointSize(8, resolution: resolution) == 14)
    #expect(InterfaceTextMetrics.pointSize(20, resolution: resolution) == 25)
  }

  @Test func settingsMapToTheResolutionTheyPromise() {
    #expect(MinimumTextSize.system.points == nil)
    #expect(MinimumTextSize.points14.points == 14)
    #expect(InterfaceTextScale.system.factor == 1)
    #expect(InterfaceTextScale.percent125.factor == 1.25)
  }
}
