import AppKit
import CoreGraphics
import Foundation

/// Whether the user sits at this Mac (docs-ai 095 "Presence"): the screen is unlocked, the
/// display is awake, and there was keyboard or mouse input in the last 2 minutes.
@MainActor
final class MacPresenceMonitor {
  static let idleThreshold: TimeInterval = 120
  static let pollInterval: Duration = .seconds(10)

  private(set) var isPresent = true
  var onChange: ((Bool) -> Void)?

  private var isLocked = false
  private var isDisplayAsleep = false
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var pollTask: Task<Void, Never>?
  private let idleSeconds: () -> TimeInterval
  private let screenLocked: () -> Bool
  private let displayAsleep: () -> Bool
  private let observesSystem: Bool
  private let clock: any Clock<Duration>

  /// The defaults read this Mac. Tests pass fixed values and `observesSystem: false`, so the
  /// real lock and display state cannot change their outcome.
  init(
    idleSeconds: @escaping () -> TimeInterval = {
      // Reading the idle time needs no permission.
      CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    },
    screenLocked: @escaping () -> Bool = { MacPresenceMonitor.screenIsLocked() },
    displayAsleep: @escaping () -> Bool = { CGDisplayIsAsleep(CGMainDisplayID()) != 0 },
    observesSystem: Bool = true,
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.idleSeconds = idleSeconds
    self.screenLocked = screenLocked
    self.displayAsleep = displayAsleep
    self.observesSystem = observesSystem
    self.clock = clock
  }

  private(set) var isRunning = false

  func start() {
    guard !isRunning else { return }
    isRunning = true
    isLocked = screenLocked()
    isDisplayAsleep = displayAsleep()
    guard observesSystem else {
      evaluate()
      return
    }
    let distributed = DistributedNotificationCenter.default()
    let workspace = NSWorkspace.shared.notificationCenter
    observe(distributed, "com.apple.screenIsLocked", .locked(true))
    observe(distributed, "com.apple.screenIsUnlocked", .locked(false))
    observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue, .displayAsleep(true))
    observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue, .displayAsleep(false))
    let clock = clock
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: Self.pollInterval) } catch { return }
        self?.evaluate()
      }
    }
    evaluate()
  }

  func stop() {
    isRunning = false
    pollTask?.cancel()
    pollTask = nil
    for (center, token) in observers { center.removeObserver(token) }
    observers.removeAll()
    isPresent = true
  }

  /// Test seams for the system notifications.
  func screenLockChanged(_ locked: Bool) {
    isLocked = locked
    evaluate()
  }

  func displaySleepChanged(_ asleep: Bool) {
    isDisplayAsleep = asleep
    evaluate()
  }

  func evaluate() {
    let present = !isLocked && !isDisplayAsleep && idleSeconds() < Self.idleThreshold
    guard present != isPresent else { return }
    isPresent = present
    onChange?(present)
  }

  private enum Change: Sendable {
    case locked(Bool)
    case displayAsleep(Bool)
  }

  private func observe(_ center: NotificationCenter, _ name: String, _ change: Change) {
    let token = center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        switch change {
        case .locked(let locked): self?.screenLockChanged(locked)
        case .displayAsleep(let asleep): self?.displaySleepChanged(asleep)
        }
      }
    }
    observers.append((center, token))
  }

  nonisolated static func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
  }
}
