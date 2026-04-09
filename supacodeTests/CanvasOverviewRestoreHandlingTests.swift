import CoreGraphics
import Foundation
import Testing

@testable import supacode

@MainActor
struct CanvasOverviewRestoreHandlingTests {
  @Test func returnsNilWhenSnapshotMissing() {
    let restored = canvasOverviewRestoreViewportState(
      snapshot: nil,
      latestCommandToken: UUID()
    )

    #expect(restored == nil)
  }

  @Test func returnsViewportStateWhenSnapshotIsLatest() {
    let token = UUID()
    let snapshot = CanvasOverviewRestoreSnapshot(
      commandToken: token,
      viewportState: CanvasView.ViewportState(
        offset: CGSize(width: 120, height: -45),
        scale: 0.8,
        hasPerformedInitialFit: true
      )
    )

    let restored = canvasOverviewRestoreViewportState(
      snapshot: snapshot,
      latestCommandToken: token
    )

    #expect(restored == snapshot.viewportState)
  }

  @Test func reusesExistingViewportSnapshotWhenOverviewRetriggered() {
    let existingSnapshot = CanvasOverviewRestoreSnapshot(
      commandToken: UUID(),
      viewportState: CanvasView.ViewportState(
        offset: CGSize(width: -180, height: 90),
        scale: 1.3,
        hasPerformedInitialFit: true
      )
    )
    let currentViewportState = CanvasView.ViewportState(
      offset: CGSize(width: 20, height: -30),
      scale: 0.4,
      hasPerformedInitialFit: true
    )
    let nextToken = UUID()

    let snapshot = canvasOverviewRestoreSnapshot(
      existingSnapshot: existingSnapshot,
      currentViewportState: currentViewportState,
      commandToken: nextToken
    )

    #expect(snapshot.commandToken == nextToken)
    #expect(snapshot.viewportState == existingSnapshot.viewportState)
  }

  @Test func returnsNilWhenNewerOverviewRequestReplacedSnapshot() {
    let snapshot = CanvasOverviewRestoreSnapshot(
      commandToken: UUID(),
      viewportState: CanvasView.ViewportState(
        offset: CGSize(width: 40, height: 10),
        scale: 1.0,
        hasPerformedInitialFit: true
      )
    )

    let restored = canvasOverviewRestoreViewportState(
      snapshot: snapshot,
      latestCommandToken: UUID()
    )

    #expect(restored == nil)
  }
}
