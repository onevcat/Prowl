import ComposableArchitecture
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct WorkflowHistoryFeatureTests {
  nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func loadedSummaryCountsRunsAndBytes() async {
    let preview = WorkflowHistoryPreview(
      entries: [Self.entry(bytes: 30), Self.entry(bytes: 12, removable: false)], now: Self.now)
    let store = TestStore(initialState: WorkflowHistoryFeature.State()) {
      WorkflowHistoryFeature()
    } withDependencies: {
      $0[WorkflowHistoryOperations.self].preview = { preview }
    }
    await store.send(.refresh) { $0.isBusy = true }
    await store.receive(\.loaded) {
      $0.isBusy = false
      $0.hasLoaded = true
      $0.preview = preview
    }
    #expect(store.state.runCount == 2)
    #expect(store.state.totalBytes == 42)
    #expect(store.state.removableCount == 1)
  }

  @Test func clearRequiresConfirmationAndCancelDoesNotDelete() async {
    var state = WorkflowHistoryFeature.State()
    state.preview = WorkflowHistoryPreview(entries: [Self.entry(bytes: 1)], now: Self.now)
    let cleared = LockIsolated(0)
    let store = TestStore(initialState: state) {
      WorkflowHistoryFeature()
    } withDependencies: {
      $0[WorkflowHistoryOperations.self].clear = {
        cleared.withValue { $0 += 1 }
        return WorkflowHistoryCleanup()
      }
    }
    await store.send(.clearTapped) { $0.alert = Self.clearAlert(count: 1) }
    await store.send(.alert(.dismiss)) { $0.alert = nil }
    #expect(cleared.value == 0)
  }

  @Test func nothingRemovableMeansNoConfirmation() async {
    var state = WorkflowHistoryFeature.State()
    state.preview = WorkflowHistoryPreview(entries: [Self.entry(bytes: 1, removable: false)], now: Self.now)
    let store = TestStore(initialState: state) { WorkflowHistoryFeature() }
    await store.send(.clearTapped)
  }

  @Test func confirmedClearReportsAndRefreshes() async {
    var state = WorkflowHistoryFeature.State()
    let entries = [Self.entry(bytes: 1), Self.entry(bytes: 2)]
    state.preview = WorkflowHistoryPreview(entries: entries, now: Self.now)
    let cleanup = {
      var cleanup = WorkflowHistoryCleanup()
      cleanup.removed = entries.map(\.id)
      return cleanup
    }()
    let store = TestStore(initialState: state) {
      WorkflowHistoryFeature()
    } withDependencies: {
      $0[WorkflowHistoryOperations.self].clear = { cleanup }
      $0[WorkflowHistoryOperations.self].preview = { WorkflowHistoryPreview(entries: [], now: Self.now) }
    }
    await store.send(.clearTapped) { $0.alert = Self.clearAlert(count: 2) }
    await store.send(.alert(.presented(.confirmClear))) {
      $0.alert = nil
      $0.isBusy = true
    }
    await store.receive(.cleared(cleanup)) { $0.result = "Removed 2 runs." }
    await store.receive(\.loaded) {
      $0.isBusy = false
      $0.hasLoaded = true
      $0.preview = WorkflowHistoryPreview(entries: [], now: Self.now)
    }
  }

  @Test func failedLoadShowsErrorAndClearsBusyState() async {
    let store = TestStore(initialState: WorkflowHistoryFeature.State()) {
      WorkflowHistoryFeature()
    } withDependencies: {
      $0[WorkflowHistoryOperations.self].preview = { throw WorkflowHistoryError.occupied }
    }
    await store.send(.refresh) { $0.isBusy = true }
    await store.receive(\.failed) {
      $0.isBusy = false
      $0.error = "occupied"
    }
  }

  nonisolated private static func entry(bytes: Int64, removable: Bool = true) -> WorkflowHistoryEntry {
    WorkflowHistoryEntry(
      id: UUID(), directory: URL(filePath: "/fixture"), name: "Run", root: "/project",
      state: removable ? "completed" : "running", finishedAt: removable ? now.addingTimeInterval(-86400 * 5) : nil,
      bytes: bytes, protection: removable ? nil : "Active or unknown state", removable: removable)
  }

  private static func clearAlert(count: Int) -> AlertState<WorkflowHistoryFeature.Alert> {
    AlertState {
      TextState("Clear Workflow History?")
    } actions: {
      ButtonState(role: .cancel) { TextState("Cancel") }
      ButtonState(role: .destructive, action: .confirmClear) { TextState("Clear History") }
    } message: {
      TextState(
        "\(count) finished run\(count == 1 ? "" : "s") and their prompts, deliveries, and action outputs "
          + "will be deleted. Runs that are still active are kept. This cannot be undone.")
    }
  }
}
