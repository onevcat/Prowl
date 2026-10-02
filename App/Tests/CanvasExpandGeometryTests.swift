import CoreGraphics
import Foundation
import Testing

@testable import supacode

struct CanvasExpandGeometryTests {
  private let metrics = CanvasExpandGeometry.Metrics(
    padding: 40,
    bottomReserve: 50,
    titleBarHeight: 28,
    minSize: CGSize(width: 300, height: 200)
  )

  @Test func sizeFillsViewportMinusPaddingAndBottomReserve() {
    let size = CanvasExpandGeometry.expandedSize(
      viewport: CGSize(width: 2000, height: 1400),
      metrics: metrics
    )
    let expectedWidth: CGFloat = 2000 - 40 * 2
    let expectedHeight: CGFloat = 1400 - 40 * 2 - 50 - 28
    #expect(size.width == expectedWidth)
    #expect(size.height == expectedHeight)
  }

  @Test func clampsToMinSizeOnTinyViewport() {
    let size = CanvasExpandGeometry.expandedSize(
      viewport: CGSize(width: 200, height: 150),
      metrics: metrics
    )
    #expect(size.width == metrics.minSize.width)
    #expect(size.height == metrics.minSize.height)
  }
}
