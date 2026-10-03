import AppKit
import SwiftUI

@MainActor
@Observable
final class CommandKeyObserver {
  private static let holdDelay: Duration = .milliseconds(300)

  var isPressed: Bool
  private var monitor: Any?
  private var didBecomeActiveObserver: NSObjectProtocol?
  private var didResignActiveObserver: NSObjectProtocol?
  private var holdTask: Task<Void, Never>?

  init() {
    isPressed = false
    monitor = nil
    didBecomeActiveObserver = nil
    didResignActiveObserver = nil
    holdTask = nil
    configureObservers()
  }

  private func configureObservers() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated {
        self?.handleCommandKeyChange(isDown: Self.shouldShowShortcuts(for: event.modifierFlags))
      }
      return event
    }
    let center = NotificationCenter.default
    didBecomeActiveObserver = center.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleCommandKeyChange(isDown: Self.shouldShowShortcuts(for: NSEvent.modifierFlags))
      }
    }
    didResignActiveObserver = center.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleCommandKeyChange(isDown: false)
      }
    }
  }

  nonisolated static func shouldShowShortcuts(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
    let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command || modifiers == .control
  }

  private func handleCommandKeyChange(isDown: Bool) {
    holdTask?.cancel()
    holdTask = nil

    if isDown {
      holdTask = Task {
        try? await ContinuousClock().sleep(for: Self.holdDelay)
        guard !Task.isCancelled else { return }
        isPressed = true
      }
    } else {
      isPressed = false
    }
  }
}
