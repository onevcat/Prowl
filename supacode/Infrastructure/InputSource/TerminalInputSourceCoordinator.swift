import Foundation

internal enum InputSourceTargetID: Hashable, Sendable {
  case surface(UUID)
  case herdrPane(String)

  fileprivate var logValue: String {
    switch self {
    case .surface(let id):
      return "surface:\(id.uuidString.prefix(8))"
    case .herdrPane(let id):
      return "herdr:\(id)"
    }
  }
}

@MainActor
internal final class TerminalInputSourceCoordinator {
  internal enum Reason: String, Sendable {
    case focusChanged
    case appBecameActive
    case processContextChanged
  }

  private let selector: KeyboardInputSourceSelecting
  private let logger = SupaLogger("InputSource")
  private var focusedTargetID: InputSourceTargetID?
  private var focusedContext: TerminalInputContext = .unknown
  private var savedInputSourceByChatTarget: [InputSourceTargetID: String] = [:]
  private var fallbackChatInputSourceID: String?

  internal init(selector: KeyboardInputSourceSelecting = KeyboardInputSourceSelector()) {
    self.selector = selector
  }

  internal func applyFocusedContext(
    _ context: TerminalInputContext,
    targetID: InputSourceTargetID,
    reason: Reason
  ) {
    rememberFallbackChatInputSourceIfNeeded(nextContext: context)
    saveFocusedChatInputSourceIfNeeded(nextTargetID: targetID, nextContext: context)
    focusedTargetID = targetID
    focusedContext = context

    switch context {
    case .chatAgent:
      restoreChatInputSourceIfNeeded(targetID: targetID, reason: reason)
    case .commandLike:
      if selector.selectABC() {
        logger.debug("selected ABC for target=\(targetID.logValue) reason=\(reason.rawValue)")
      }
    case .unknown:
      logger.debug("input source unchanged for unknown context target=\(targetID.logValue)")
    }
  }

  private func rememberFallbackChatInputSourceIfNeeded(nextContext: TerminalInputContext) {
    guard nextContext == .commandLike else { return }
    guard let currentID = selector.currentInputSourceID() else { return }
    guard currentID != KeyboardInputSourceSelector.abcInputSourceID else { return }
    fallbackChatInputSourceID = currentID
  }

  private func saveFocusedChatInputSourceIfNeeded(
    nextTargetID: InputSourceTargetID,
    nextContext: TerminalInputContext
  ) {
    guard let focusedTargetID else { return }
    guard focusedContext == .chatAgent else { return }
    guard focusedTargetID != nextTargetID || nextContext != .chatAgent else { return }
    guard let currentID = selector.currentInputSourceID() else { return }
    savedInputSourceByChatTarget[focusedTargetID] = currentID
    fallbackChatInputSourceID = currentID
  }

  private func restoreChatInputSourceIfNeeded(targetID: InputSourceTargetID, reason: Reason) {
    guard let savedID = savedInputSourceByChatTarget[targetID] ?? fallbackChatInputSourceID else {
      logger.debug(
        "chat agent has no saved input source target=\(targetID.logValue) reason=\(reason.rawValue)"
      )
      return
    }
    if selector.selectInputSource(id: savedID) {
      logger.debug(
        "restored input source for chat target=\(targetID.logValue) reason=\(reason.rawValue)"
      )
    }
  }
}
