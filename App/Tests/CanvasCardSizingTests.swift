import CoreGraphics
import Foundation
import Testing

@testable import supacode

struct CanvasCardSizingTests {
  @Test func smallScreenClampsToMinSize() {
    let size = CanvasCardLayout.adaptiveDefaultSize(forScreenWidth: 1280)
    #expect(size == CanvasCardLayout.minDefaultSize)
  }

  @Test func atMinReferenceWidthReturnsMinSize() {
    let size = CanvasCardLayout.adaptiveDefaultSize(
      forScreenWidth: CanvasCardLayout.minDefaultScreenWidth
    )
    #expect(size == CanvasCardLayout.minDefaultSize)
  }

  @Test func largeScreenClampsToMaxSize() {
    let size = CanvasCardLayout.adaptiveDefaultSize(forScreenWidth: 3840)
    #expect(size == CanvasCardLayout.maxDefaultSize)
  }

  @Test func atMaxReferenceWidthReturnsMaxSize() {
    let size = CanvasCardLayout.adaptiveDefaultSize(
      forScreenWidth: CanvasCardLayout.maxDefaultScreenWidth
    )
    #expect(size == CanvasCardLayout.maxDefaultSize)
  }

  @Test func midpointInterpolatesLinearly() {
    let midWidth =
      (CanvasCardLayout.minDefaultScreenWidth + CanvasCardLayout.maxDefaultScreenWidth) / 2
    let size = CanvasCardLayout.adaptiveDefaultSize(forScreenWidth: midWidth)
    let expectedWidth =
      (CanvasCardLayout.minDefaultSize.width + CanvasCardLayout.maxDefaultSize.width) / 2
    let expectedHeight =
      (CanvasCardLayout.minDefaultSize.height + CanvasCardLayout.maxDefaultSize.height) / 2
    #expect(abs(size.width - expectedWidth) < 0.001)
    #expect(abs(size.height - expectedHeight) < 0.001)
  }

  @Test func sizeGrowsMonotonicallyWithScreenWidth() {
    let small = CanvasCardLayout.adaptiveDefaultSize(forScreenWidth: 1600)
    let medium = CanvasCardLayout.adaptiveDefaultSize(forScreenWidth: 2000)
    let large = CanvasCardLayout.adaptiveDefaultSize(forScreenWidth: 2400)
    #expect(small.width < medium.width)
    #expect(medium.width < large.width)
    #expect(small.height < medium.height)
    #expect(medium.height < large.height)
  }
}
