import CoreGraphics
import Foundation
import Testing

@testable import supacode

@MainActor
struct CanvasFocusFallbackSelectionTests {
  @Test func keepsFocusedTabWhenItStillExists() {
    let candidates = [
      CanvasFocusFallbackCandidate(
        id: "focused",
        center: CGPoint(x: 1_200, y: 900),
        size: CGSize(width: 800, height: 600),
        isSelected: false
      ),
      CanvasFocusFallbackCandidate(
        id: "other",
        center: CGPoint(x: 400, y: 300),
        size: CGSize(width: 800, height: 600),
        isSelected: true
      ),
    ]

    let result = canvasFallbackFocusID(
      focusedID: "focused",
      viewportSize: CGSize(width: 1_000, height: 700),
      canvasOffset: .zero,
      canvasScale: 1.0,
      candidates: candidates
    )

    #expect(result == "focused")
  }

  @Test func choosesNearestSelectedWhenFocusedMissing() {
    let candidates = [
      CanvasFocusFallbackCandidate(
        id: "selected-near",
        center: CGPoint(x: 520, y: 360),
        size: CGSize(width: 300, height: 200),
        isSelected: true
      ),
      CanvasFocusFallbackCandidate(
        id: "selected-far",
        center: CGPoint(x: 120, y: 120),
        size: CGSize(width: 300, height: 200),
        isSelected: true
      ),
      CanvasFocusFallbackCandidate(
        id: "non-selected",
        center: CGPoint(x: 500, y: 350),
        size: CGSize(width: 300, height: 200),
        isSelected: false
      ),
    ]

    let result = canvasFallbackFocusID(
      focusedID: "missing",
      viewportSize: CGSize(width: 1_000, height: 700),
      canvasOffset: .zero,
      canvasScale: 1.0,
      candidates: candidates
    )

    #expect(result == "selected-near")
  }

  @Test func prioritizesPendingCreatedTabWhenAvailable() {
    let candidates = [
      CanvasFocusFallbackCandidate(
        id: "selected-near",
        center: CGPoint(x: 520, y: 360),
        size: CGSize(width: 300, height: 200),
        isSelected: true
      ),
      CanvasFocusFallbackCandidate(
        id: "pending-created",
        center: CGPoint(x: 1_600, y: 1_200),
        size: CGSize(width: 300, height: 200),
        isSelected: true
      ),
    ]

    let result = canvasFallbackFocusID(
      focusedID: nil,
      pendingCreatedID: "pending-created",
      viewportSize: CGSize(width: 1_000, height: 700),
      canvasOffset: .zero,
      canvasScale: 1.0,
      candidates: candidates
    )

    #expect(result == "pending-created")
  }

  @Test func choosesNearestVisibleWhenNoFocusedOrSelected() {
    let candidates = [
      CanvasFocusFallbackCandidate(
        id: "near-visible",
        center: CGPoint(x: 520, y: 340),
        size: CGSize(width: 300, height: 200),
        isSelected: false
      ),
      CanvasFocusFallbackCandidate(
        id: "far-visible",
        center: CGPoint(x: 100, y: 100),
        size: CGSize(width: 300, height: 200),
        isSelected: false
      ),
      CanvasFocusFallbackCandidate(
        id: "offscreen",
        center: CGPoint(x: 1_700, y: 1_200),
        size: CGSize(width: 300, height: 200),
        isSelected: false
      ),
    ]

    let result = canvasFallbackFocusID(
      focusedID: nil,
      viewportSize: CGSize(width: 1_000, height: 700),
      canvasOffset: .zero,
      canvasScale: 1.0,
      candidates: candidates
    )

    #expect(result == "near-visible")
  }

  @Test func fallsBackToNearestOverallWhenNothingVisible() {
    let candidates = [
      CanvasFocusFallbackCandidate(
        id: "near-overall",
        center: CGPoint(x: 900, y: 700),
        size: CGSize(width: 200, height: 120),
        isSelected: false
      ),
      CanvasFocusFallbackCandidate(
        id: "far-overall",
        center: CGPoint(x: 1_800, y: 1_500),
        size: CGSize(width: 200, height: 120),
        isSelected: false
      ),
    ]

    let result = canvasFallbackFocusID(
      focusedID: nil,
      viewportSize: CGSize(width: 500, height: 300),
      canvasOffset: .zero,
      canvasScale: 1.0,
      candidates: candidates
    )

    #expect(result == "near-overall")
  }
}
