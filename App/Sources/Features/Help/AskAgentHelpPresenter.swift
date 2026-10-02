import Observation

/// Shared trigger for the "Ask an agent about Prowl" help dialog.
///
/// Both the sidebar Help menu and the macOS Help menu set `isPresented`; the
/// main window observes it and presents the sheet. It's transient UI state, so
/// it lives in a lightweight `@Observable` store rather than the TCA tree.
@MainActor
@Observable
final class AskAgentHelpPresenter {
  var isPresented = false

  func present() {
    isPresented = true
  }

  func dismiss() {
    isPresented = false
  }
}
