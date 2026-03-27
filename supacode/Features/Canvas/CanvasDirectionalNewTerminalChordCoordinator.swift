import AppKit
import Carbon

@MainActor
final class CanvasDirectionalNewTerminalChordCoordinator {
  static let shared = CanvasDirectionalNewTerminalChordCoordinator()

  private(set) var isCanvasActive = false
  private(set) var isAwaitingDirectionalChordKey = false

  private init() {}

  func setCanvasActive(_ isActive: Bool) {
    isCanvasActive = isActive
    if !isActive {
      isAwaitingDirectionalChordKey = false
    }
  }

  func setAwaitingDirectionalChordKey(_ isAwaiting: Bool) {
    guard isCanvasActive else {
      isAwaitingDirectionalChordKey = false
      return
    }
    isAwaitingDirectionalChordKey = isAwaiting
  }

  func shouldBlockTerminalInput(_ event: NSEvent) -> Bool {
    guard isCanvasActive, isAwaitingDirectionalChordKey else { return false }
    return Self.isDirectionalChordConsumableKey(
      keyCode: event.keyCode,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers
    )
  }

  static func isDirectionalChordConsumableKey(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?
  ) -> Bool {
    switch Int(keyCode) {
    case kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_N, kVK_Escape:
      return true
    default:
      break
    }
    guard let charactersIgnoringModifiers else { return false }
    let normalized = charactersIgnoringModifiers.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.count == 1 else { return false }
    return ["h", "j", "k", "l", "n"].contains(normalized)
  }
}
