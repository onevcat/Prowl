import Foundation

struct CanvasOverviewRestoreSnapshot: Equatable {
  let commandToken: UUID
  let viewportState: CanvasView.ViewportState
}

func canvasOverviewRestoreSnapshot(
  existingSnapshot: CanvasOverviewRestoreSnapshot?,
  currentViewportState: CanvasView.ViewportState,
  commandToken: UUID
) -> CanvasOverviewRestoreSnapshot {
  CanvasOverviewRestoreSnapshot(
    commandToken: commandToken,
    viewportState: existingSnapshot?.viewportState ?? currentViewportState
  )
}

func canvasOverviewRestoreViewportState(
  snapshot: CanvasOverviewRestoreSnapshot?,
  latestCommandToken: UUID?
) -> CanvasView.ViewportState? {
  guard let snapshot else { return nil }
  guard snapshot.commandToken == latestCommandToken else { return nil }
  return snapshot.viewportState
}
