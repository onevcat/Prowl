import Foundation

@MainActor
internal final class TerminalInputSourceCoordinator {
  internal enum Reason: String, Sendable {
    case focusChanged
    case appBecameActive
    case processContextChanged
  }

  private let selector: KeyboardInputSourceSelecting
  private let logger = SupaLogger("InputSource")
  private var focusedSurfaceID: UUID?
  private var focusedContext: TerminalInputContext = .unknown
  private var savedInputSourceByChatSurface: [UUID: String] = [:]

  internal init(selector: KeyboardInputSourceSelecting = KeyboardInputSourceSelector()) {
    self.selector = selector
  }

  internal func applyFocusedContext(
    _ context: TerminalInputContext,
    surfaceID: UUID,
    reason: Reason
  ) {
    saveFocusedChatInputSourceIfNeeded(nextSurfaceID: surfaceID, nextContext: context)
    focusedSurfaceID = surfaceID
    focusedContext = context

    switch context {
    case .chatAgent:
      restoreChatInputSourceIfNeeded(surfaceID: surfaceID, reason: reason)
    case .commandLike:
      if selector.selectABC() {
        logger.debug("selected ABC for surface=\(surfaceID.uuidString.prefix(8)) reason=\(reason.rawValue)")
      }
    case .unknown:
      logger.debug("input source unchanged for unknown context surface=\(surfaceID.uuidString.prefix(8))")
    }
  }

  private func saveFocusedChatInputSourceIfNeeded(
    nextSurfaceID: UUID,
    nextContext: TerminalInputContext
  ) {
    guard let focusedSurfaceID else { return }
    guard focusedContext == .chatAgent else { return }
    guard focusedSurfaceID != nextSurfaceID || nextContext != .chatAgent else { return }
    guard let currentID = selector.currentInputSourceID() else { return }
    savedInputSourceByChatSurface[focusedSurfaceID] = currentID
  }

  private func restoreChatInputSourceIfNeeded(surfaceID: UUID, reason: Reason) {
    guard let savedID = savedInputSourceByChatSurface[surfaceID] else {
      let surfaceLogID = surfaceID.uuidString.prefix(8)
      logger.debug("chat agent has no saved input source surface=\(surfaceLogID) reason=\(reason.rawValue)")
      return
    }
    if selector.selectInputSource(id: savedID) {
      logger.debug("restored input source for chat surface=\(surfaceID.uuidString.prefix(8)) reason=\(reason.rawValue)")
    }
  }
}
