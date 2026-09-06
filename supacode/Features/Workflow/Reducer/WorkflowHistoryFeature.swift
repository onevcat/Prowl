import AppKit
import ComposableArchitecture
import Foundation
import ProwlCLIShared
import UniformTypeIdentifiers

struct WorkflowHistoryOperations: DependencyKey, Sendable {
  var preview: @Sendable () async throws -> WorkflowHistoryPreview
  var keep: @Sendable (URL, Bool) async throws -> Void
  var cleanup: @Sendable ([UUID]) async throws -> WorkflowHistoryCleanup
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
      keep: { directory, pinned in
        let storage = WorkflowHistoryStorage.configured
        try await Task.detached(priority: .utility) {
          try WorkflowHistory(storage: storage).keep(directory, pinned: pinned)
        }.value
      },
      cleanup: { ids in
        let storage = WorkflowHistoryStorage.configured
        @Dependency(\.date.now) var now
        let timestamp = now
        return try await Task.detached(priority: .utility) {
          try WorkflowHistory(storage: storage).cleanup(candidates: ids, now: timestamp)
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
    keep: { _, _ in }, cleanup: { _ in WorkflowHistoryCleanup() }, export: { _ in nil })
}

@Reducer
struct WorkflowHistoryFeature {
  @ObservableState
  struct State: Equatable {
    var preview = WorkflowHistoryPreview(entries: [], now: Date(timeIntervalSince1970: 0))
    var confirmation: WorkflowHistoryPreview?
    var isBusy = false
    var query = ""
    var error: String?
    var result: String?

    var entries: [WorkflowHistoryEntry] {
      preview.entries.filter {
        query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
          || $0.root.localizedCaseInsensitiveContains(query) || $0.id.uuidString.localizedCaseInsensitiveContains(query)
      }.sorted { ($0.finishedAt ?? .distantFuture) > ($1.finishedAt ?? .distantFuture) }
    }
  }

  enum Action: Equatable {
    case refresh
    case loaded(WorkflowHistoryPreview)
    case failed(String)
    case setQuery(String)
    case keep(URL, Bool)
    case export(URL)
    case exported(URL?)
    case previewCleanup
    case dismissCleanup
    case confirmCleanup
    case cleaned(WorkflowHistoryCleanup)
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
        state.isBusy = false
        state.preview = preview
        return .none
      case .failed(let message):
        state.isBusy = false
        state.error = message
        return .none
      case .setQuery(let query):
        state.query = query
        return .none
      case .keep(let directory, let pinned):
        guard !state.isBusy else { return .none }
        state.isBusy = true
        return .run { send in
          do {
            try await operations.keep(directory, pinned)
            await send(.loaded(try await operations.preview()))
          } catch { await send(.failed(String(describing: error))) }
        }
      case .export(let directory):
        guard !state.isBusy else { return .none }
        state.isBusy = true
        return .run { send in
          do { await send(.exported(try await operations.export(directory))) } catch {
            await send(.failed(String(describing: error)))
          }
        }
      case .exported(let destination):
        state.isBusy = false
        state.result = destination.map { "Exported to \($0.path). This ZIP is independent of history cleanup." }
        return .none
      case .previewCleanup:
        guard !state.isBusy else { return .none }
        state.confirmation = state.preview
        return .none
      case .dismissCleanup:
        state.confirmation = nil
        return .none
      case .confirmCleanup:
        guard !state.isBusy, let preview = state.confirmation else { return .none }
        state.confirmation = nil
        state.isBusy = true
        state.error = nil
        return .run { send in
          do { await send(.cleaned(try await operations.cleanup(preview.candidates.map(\.id)))) } catch {
            await send(.failed(String(describing: error)))
          }
        }
      case .cleaned(let result):
        state.isBusy = true
        state.result = "Removed \(result.removed.count) run(s). Runs whose eligibility changed were preserved."
        state.error = result.failures.isEmpty ? nil : result.failures.joined(separator: "\n")
        return .run { send in
          do { await send(.loaded(try await operations.preview())) } catch {
            await send(.failed(String(describing: error)))
          }
        }
      }
    }
  }
}
