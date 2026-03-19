import AppKit
import CoreGraphics
import Testing

@testable import supacode

struct CanvasOptionScrollRouterTests {
  private let canvasBounds = CGRect(x: 0, y: 0, width: 800, height: 600)

  @Test func routesWhenOptionPressedPointerInsideAndWindowMatches() {
    #expect(
      CanvasOptionScrollRouter.shouldRouteToCanvas(
        modifierFlags: [.option],
        eventWindowNumber: 9,
        canvasWindowNumber: 9,
        hasPreciseScrollingDeltas: true,
        locationInCanvas: CGPoint(x: 200, y: 200),
        canvasBounds: canvasBounds
      )
    )
  }

  @Test func doesNotRouteWithoutOption() {
    #expect(
      !CanvasOptionScrollRouter.shouldRouteToCanvas(
        modifierFlags: [],
        eventWindowNumber: 9,
        canvasWindowNumber: 9,
        hasPreciseScrollingDeltas: true,
        locationInCanvas: CGPoint(x: 200, y: 200),
        canvasBounds: canvasBounds
      )
    )
  }

  @Test func doesNotRouteWithCommandOnly() {
    #expect(
      !CanvasOptionScrollRouter.shouldRouteToCanvas(
        modifierFlags: [.command],
        eventWindowNumber: 9,
        canvasWindowNumber: 9,
        hasPreciseScrollingDeltas: true,
        locationInCanvas: CGPoint(x: 200, y: 200),
        canvasBounds: canvasBounds
      )
    )
  }

  @Test func doesNotRouteWhenWindowDiffers() {
    #expect(
      !CanvasOptionScrollRouter.shouldRouteToCanvas(
        modifierFlags: [.option],
        eventWindowNumber: 10,
        canvasWindowNumber: 9,
        hasPreciseScrollingDeltas: true,
        locationInCanvas: CGPoint(x: 200, y: 200),
        canvasBounds: canvasBounds
      )
    )
  }

  @Test func doesNotRouteWhenPointerOutsideCanvas() {
    #expect(
      !CanvasOptionScrollRouter.shouldRouteToCanvas(
        modifierFlags: [.option],
        eventWindowNumber: 9,
        canvasWindowNumber: 9,
        hasPreciseScrollingDeltas: true,
        locationInCanvas: CGPoint(x: 1000, y: 200),
        canvasBounds: canvasBounds
      )
    )
  }

  @Test func doesNotRouteForNonPreciseScroll() {
    #expect(
      !CanvasOptionScrollRouter.shouldRouteToCanvas(
        modifierFlags: [.option],
        eventWindowNumber: 9,
        canvasWindowNumber: 9,
        hasPreciseScrollingDeltas: false,
        locationInCanvas: CGPoint(x: 200, y: 200),
        canvasBounds: canvasBounds
      )
    )
  }
}
