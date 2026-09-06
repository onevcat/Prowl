import ComposableArchitecture
import Foundation
import ProwlCLIShared

struct WorkflowBundleReviewClient: Sendable {
  var load: @Sendable (URL, WorkflowScope) throws -> WorkflowBundleReview
  var approve: @Sendable (WorkflowBundleSnapshot) throws -> Void
  var reveal: @Sendable (URL) -> Void
}

extension WorkflowBundleReviewClient: DependencyKey {
  static let liveValue = Self(
    load: { try WorkflowBundleReview.load(url: $0, scope: $1) },
    approve: { try WorkflowBundleApprovalStore().approve($0, now: Date()) },
    reveal: { WorkflowSettingsClient.reveal($0) })
  static let testValue = Self(
    load: { _, _ in throw WorkflowExpressionError.missing("Configure bundle review in the test.") },
    approve: { _ in throw WorkflowExpressionError.missing("Configure bundle approval in the test.") },
    reveal: { _ in })
}
