import AppKit
import ComposableArchitecture
import Foundation
import ProwlCLIShared
import UniformTypeIdentifiers

struct WorkflowHistoryOperations: DependencyKey, Sendable {
  var preview: @Sendable () async throws -> WorkflowHistoryPreview
  /// Removes one finished run on explicit request (Workflow History › Delete Run).
  var delete: @Sendable (URL) async throws -> Void
  /// Removes every finished run that is not in use (Settings › Clear History).
  var clear: @Sendable () async throws -> WorkflowHistoryCleanup
  var export: @MainActor @Sendable (URL) async throws -> URL?

  static var liveValue: Self {
    Self(
      preview: {
        let storage = WorkflowHistoryStorage.configured
        @Dependency(\.date.now) var now
        let timestamp = now
        return try await Task.detached(priority: .utility) {
          try WorkflowHistory(storage: storage).preview(now: timestamp)
        }.value
      },
      delete: { directory in
        let storage = WorkflowHistoryStorage.configured
        @Dependency(\.date.now) var now
        let timestamp = now
        try await Task.detached(priority: .utility) {
          try WorkflowHistory(storage: storage).delete(directory, now: timestamp)
        }.value
      },
      clear: {
        let storage = WorkflowHistoryStorage.configured
        @Dependency(\.date.now) var now
        let timestamp = now
        return try await Task.detached(priority: .utility) {
          try WorkflowHistory(storage: storage).clear(now: timestamp)
        }.value
      },
      export: { directory in
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "workflow-\(directory.lastPathComponent).zip"
        guard await panel.begin() == .OK, let destination = panel.url else { return nil }
        let storage = WorkflowHistoryStorage.configured
        try await Task.detached(priority: .utility) {
          try WorkflowHistory(storage: storage).export(directory, to: destination)
        }.value
        return destination
      })
  }

  static let testValue = Self(
    preview: { WorkflowHistoryPreview(entries: [], now: Date(timeIntervalSince1970: 0)) },
    delete: { _ in }, clear: { WorkflowHistoryCleanup() }, export: { _ in nil })
}

/// The Settings › Workflows history summary: how much the archive holds and a way to clear it.
/// Retention itself is automatic (`WorkflowHistoryPreview.retention`) and not a user setting.
@Reducer
struct WorkflowHistoryFeature {
  @ObservableState
  struct State: Equatable {
    var preview = WorkflowHistoryPreview(entries: [], now: Date(timeIntervalSince1970: 0))
    var hasLoaded = false
    var isBusy = false
    var error: String?
    var result: String?
    @Presents var alert: AlertState<Alert>?

    var runCount: Int { preview.entries.count }
    var totalBytes: Int64 { preview.totalBytes }
    /// Finished runs an explicit Clear may remove; live runs stay.
    var removableCount: Int { preview.entries.filter(\.removable).count }
  }

  enum Action: Equatable {
    case refresh
    case loaded(WorkflowHistoryPreview)
    case failed(String)
    case clearTapped
    case cleared(WorkflowHistoryCleanup)
    case alert(PresentationAction<Alert>)
  }

  enum Alert: Equatable {
    case confirmClear
  }

  @Dependency(WorkflowHistoryOperations.self) var operations

  var body: some Reducer<State, Action> {
    Reduce<State, Action> { state, action in
      switch action {
      case .refresh:
        guard !state.isBusy else { return .none }
        state.isBusy = true
        state.error = nil
        return .run { send in
          do { await send(.loaded(try await operations.preview())) } catch {
            await send(.failed(String(describing: error)))
          }
        }
      case .loaded(let preview):
        state.error = nil
        state.isBusy = false
        state.hasLoaded = true
        state.preview = preview
        return .none
      case .failed(let message):
        state.isBusy = false
        state.error = message
        return .none
      case .clearTapped:
        guard !state.isBusy, state.removableCount > 0 else { return .none }
        let count = state.removableCount
        state.alert = AlertState {
          TextState("Clear Workflow History?")
        } actions: {
          ButtonState(role: .cancel) { TextState("Cancel") }
          ButtonState(role: .destructive, action: .confirmClear) { TextState("Clear History") }
        } message: {
          TextState(
            "\(count) finished run\(count == 1 ? "" : "s") and their prompts, deliveries, and action outputs "
              + "will be deleted. Runs that are still active are kept. This cannot be undone.")
        }
        return .none
      case .alert(.presented(.confirmClear)):
        guard !state.isBusy else { return .none }
        state.isBusy = true
        state.error = nil
        state.result = nil
        return .run { send in
          do { await send(.cleared(try await operations.clear())) } catch {
            await send(.failed(String(describing: error)))
          }
        }
      case .alert:
        return .none
      case .cleared(let cleanup):
        state.isBusy = true
        let count = cleanup.removed.count
        state.result = "Removed \(count) run\(count == 1 ? "" : "s")."
        state.error = cleanup.failures.isEmpty ? nil : cleanup.failures.joined(separator: "\n")
        return .run { send in
          do { await send(.loaded(try await operations.preview())) } catch {
            await send(.failed(String(describing: error)))
          }
        }
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}
