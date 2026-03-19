import CoreGraphics
import Foundation
import Testing

@testable import supacode

struct CanvasWrapToastVisibilityTests {
  private func entry(
    _ id: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat = 400,
    height: CGFloat = 300
  ) -> CanvasTabNavigator.Entry<String> {
    CanvasTabNavigator.Entry(
      id: id,
      center: CGPoint(x: x, y: y),
      size: CGSize(width: width, height: height)
    )
  }

  @Test func suppressesHorizontalWrapToastWhenTwoTabsFullyVisibleInX() {
    let entries = [
      entry("left", x: 200, y: 200),
      entry("right", x: 600, y: 200),
    ]

    let shouldShow = shouldShowCanvasWrapToast(
      direction: .left,
      didWrap: true,
      viewportSize: CGSize(width: 1_000, height: 700),
      canvasOffset: .zero,
      canvasScale: 1.0,
      entries: entries
    )

    #expect(shouldShow == false)
  }

  @Test func suppressesHorizontalWrapToastWhenAllTabsFullyVisibleInX() {
    let entries = [
      entry("left", x: 200, y: 200),
      entry("mid", x: 600, y: 200),
      entry("right", x: 1_000, y: 200),
    ]

    let shouldShow = shouldShowCanvasWrapToast(
      direction: .right,
      didWrap: true,
      viewportSize: CGSize(width: 1_300, height: 700),
      canvasOffset: .zero,
      canvasScale: 1.0,
      entries: entries
    )

    #expect(shouldShow == false)
  }

  @Test func keepsVerticalWrapToastEvenWhenTwoTabsFullyVisibleInX() {
    let entries = [
      entry("top", x: 200, y: 200),
      entry("bottom", x: 600, y: 500),
    ]

    let shouldShow = shouldShowCanvasWrapToast(
      direction: .up,
      didWrap: true,
      viewportSize: CGSize(width: 1_000, height: 700),
      canvasOffset: .zero,
      canvasScale: 1.0,
      entries: entries
    )

    #expect(shouldShow == true)
  }

  @Test func suppressesHorizontalWrapToastWhenTwoTabsAreStackedInOneColumn() {
    let entries = [
      entry("top", x: 220, y: 200),
      entry("bottom", x: 220, y: 560),
    ]

    let shouldShow = shouldShowCanvasWrapToast(
      direction: .left,
      didWrap: true,
      viewportSize: CGSize(width: 520, height: 800),
      canvasOffset: .zero,
      canvasScale: 1.0,
      entries: entries
    )

    #expect(shouldShow == false)
  }

  @Test func keepsHorizontalWrapToastWhenAnyTabIsNotFullyVisibleInX() {
    let entries = [
      entry("left", x: 200, y: 200),
      entry("mid", x: 600, y: 200),
      entry("right", x: 1_000, y: 200),
    ]

    let shouldShow = shouldShowCanvasWrapToast(
      direction: .right,
      didWrap: true,
      viewportSize: CGSize(width: 1_100, height: 700),
      canvasOffset: .zero,
      canvasScale: 1.0,
      entries: entries
    )

    #expect(shouldShow == true)
  }
}
