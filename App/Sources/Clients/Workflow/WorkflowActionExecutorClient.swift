// supacode/Clients/Workflow/WorkflowActionExecutorClient.swift
// The boundary the reducer runs a native `action` step through (docs-ai 063 B3): the app uses
// the bundled runner, tests substitute one they can hold or fail at will.

import ComposableArchitecture
import Foundation

enum WorkflowActionExecutorKey: DependencyKey {
  static let liveValue: any WorkflowActionExecuting = WorkflowNativeActionRunner()
  static let testValue: any WorkflowActionExecuting = WorkflowNativeActionRunner()
}

extension DependencyValues {
  var workflowActionExecutor: any WorkflowActionExecuting {
    get { self[WorkflowActionExecutorKey.self] }
    set { self[WorkflowActionExecutorKey.self] = newValue }
  }
}
