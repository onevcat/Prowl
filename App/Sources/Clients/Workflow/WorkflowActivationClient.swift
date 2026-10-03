import ComposableArchitecture
import Foundation

/// The live dispatch-store operations used only by the workflow reducer. The dispatch store
/// remains workflow-agnostic: this client translates B2's activation effects at the app boundary.
struct WorkflowActivationClient: Sendable {
  var openMessage: @MainActor @Sendable (UUID) -> Result<String, WorkflowActivationOpenFailure>
  var cancel: @MainActor @Sendable (String) -> Void
  var abandon: @MainActor @Sendable (String, String) -> Void
  var complete: @MainActor @Sendable (String, String) -> Void
  var observe: @MainActor @Sendable (String) -> AgentDispatchObservationStream?
}

extension WorkflowActivationClient: DependencyKey {
  static let liveValue = WorkflowActivationClient(
    openMessage: { _ in .failure(.failed("WorkflowActivationClient.openMessage not configured")) },
    cancel: { _ in },
    abandon: { _, _ in },
    complete: { _, _ in },
    observe: { _ in nil }
  )

  static let testValue = WorkflowActivationClient(
    openMessage: { _ in .failure(.failed("No test activation bridge configured.")) },
    cancel: { _ in },
    abandon: { _, _ in },
    complete: { _, _ in },
    observe: { _ in nil }
  )
}

extension DependencyValues {
  var workflowActivationClient: WorkflowActivationClient {
    get { self[WorkflowActivationClient.self] }
    set { self[WorkflowActivationClient.self] = newValue }
  }
}
