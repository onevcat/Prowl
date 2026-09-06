import ComposableArchitecture
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct WorkflowHistoryFeatureTests {
  @Test func previewRequiresConfirmationAndCancelDoesNotDelete() async {
    let store = TestStore(initialState: WorkflowHistoryFeature.State()) { WorkflowHistoryFeature() }
    await store.send(.previewCleanup) { $0.confirmation = $0.preview }
    await store.send(.dismissCleanup) { $0.confirmation = nil }
  }

  @Test func confirmedCleanupRefreshesBeforeAllowingAnotherOperation() async {
    let store = TestStore(initialState: WorkflowHistoryFeature.State()) { WorkflowHistoryFeature() }
    await store.send(.previewCleanup) { $0.confirmation = $0.preview }
    await store.send(.confirmCleanup) {
      $0.confirmation = nil
      $0.isBusy = true
    }
    await store.receive(.cleaned(WorkflowHistoryCleanup())) {
      $0.result = "Removed 0 run(s). Runs whose eligibility changed were preserved."
    }
    await store.receive(\.loaded) { $0.isBusy = false }
  }

  @Test func failedPinPreservesHistoryAndReportsTheFailure() async {
    let store = TestStore(initialState: WorkflowHistoryFeature.State()) {
      WorkflowHistoryFeature()
    } withDependencies: {
      $0[WorkflowHistoryOperations.self].keep = { _, _ in throw WorkflowHistoryError.occupied }
    }
    await store.send(.keep(URL(filePath: "/fixture"), true)) { $0.isBusy = true }
    await store.receive(\.failed) {
      $0.isBusy = false
      $0.error = "occupied"
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
}
