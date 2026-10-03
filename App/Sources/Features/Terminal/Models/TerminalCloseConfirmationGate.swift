import Foundation

/// App-global guard against re-entrant close-confirmation alerts.
///
/// Close requests arrive from independent paths (TCA effects, Ghostty
/// callbacks, the tab bar, the CLI socket), and `NSAlert.runModal()` keeps
/// draining main-actor jobs while it spins, so a late request can try to
/// present a second alert from inside the first one's run loop. AppKit may
/// answer that nested modal with an uncaught NSException (SIGABRT, Sentry
/// PROWL-MACOS-FP). While a confirmation is on screen, later ones are
/// dropped and treated as cancelled.
@MainActor
enum TerminalCloseConfirmationGate {
  private(set) static var isPresenting = false

  /// Runs `present` unless a confirmation is already showing.
  /// Returns `nil` when the gate is held; callers treat that as "cancelled".
  static func run<T>(_ present: () -> T) -> T? {
    guard !isPresenting else { return nil }
    isPresenting = true
    defer { isPresenting = false }
    return present()
  }
}
