import Clocks
import Observation

/// One owner for adjacent hover popovers. Callbacks from a replaced panel cannot reopen it.
@MainActor @Observable
final class ToolbarPopoverCoordinator {
  enum Destination { case notifications, history }

  private(set) var presented: Destination?
  private var pinned: Destination?
  private var hoveredButton: Destination?
  private var hoveredPopover: Destination?
  @ObservationIgnored private var closeTask: Task<Void, Never>?
  @ObservationIgnored private let clock: any Clock<Duration>

  init(clock: any Clock<Duration> = ContinuousClock()) {
    self.clock = clock
  }

  func hoverButton(_ destination: Destination, hovering: Bool) {
    if hovering {
      hoveredButton = destination
      closeTask?.cancel()
      guard pinned == nil else { return }
      if presented != destination { hoveredPopover = nil }
      presented = destination
    } else if hoveredButton == destination {
      hoveredButton = nil
      scheduleClose()
    }
  }

  func hoverPopover(_ destination: Destination, hovering: Bool) {
    guard presented == destination else { return }
    hoveredPopover = hovering ? destination : nil
    scheduleClose()
  }

  func toggle(_ destination: Destination) {
    if pinned == destination {
      dismiss(destination)
    } else {
      showPinned(destination)
    }
  }

  func showPinned(_ destination: Destination) {
    closeTask?.cancel()
    if presented != destination { hoveredPopover = nil }
    presented = destination
    pinned = destination
  }

  func pin(_ destination: Destination) {
    guard presented == destination else { return }
    showPinned(destination)
  }

  func dismiss(_ destination: Destination) {
    guard presented == destination else { return }
    closeTask?.cancel()
    presented = nil
    pinned = nil
    hoveredPopover = nil
    hoveredButton = nil
  }

  private func scheduleClose() {
    closeTask?.cancel()
    guard let destination = presented, pinned == nil, hoveredButton != destination, hoveredPopover != destination else {
      return
    }
    closeTask = Task { [weak self, clock] in
      do { try await clock.sleep(for: .milliseconds(180)) } catch { return }
      guard !Task.isCancelled else { return }
      self?.dismiss(destination)
    }
  }
}
