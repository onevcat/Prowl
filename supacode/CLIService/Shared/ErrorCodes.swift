// ProwlShared/ErrorCodes.swift
// Stable error codes matching schema.md contracts.

import Foundation

nonisolated public enum CLIErrorCode {
  // Common
  public static let appNotRunning = "APP_NOT_RUNNING"
  public static let invalidArgument = "INVALID_ARGUMENT"
  public static let targetNotFound = "TARGET_NOT_FOUND"
  public static let targetNotUnique = "TARGET_NOT_UNIQUE"

  // Open
  public static let pathNotFound = "PATH_NOT_FOUND"
  public static let pathNotDirectory = "PATH_NOT_DIRECTORY"
  public static let pathNotAllowed = "PATH_NOT_ALLOWED"
  public static let launchFailed = "LAUNCH_FAILED"
  public static let openFailed = "OPEN_FAILED"

  // List
  public static let listFailed = "LIST_FAILED"

  // Agents
  public static let agentsFailed = "AGENTS_FAILED"
  public static let agentNotFound = "AGENT_NOT_FOUND"
  public static let agentUnsupported = "AGENT_UNSUPPORTED"
  public static let agentReadFailed = "AGENT_READ_FAILED"
  public static let agentGone = "AGENT_GONE"
  public static let dispatchContextRequired = "DISPATCH_CONTEXT_REQUIRED"
  public static let dispatchSourceMismatch = "DISPATCH_SOURCE_MISMATCH"
  public static let dispatchNotFound = "DISPATCH_NOT_FOUND"
  public static let dispatchCapacityExceeded = "DISPATCH_CAPACITY_EXCEEDED"
  public static let dispatchAlreadyCompleted = "DISPATCH_ALREADY_COMPLETED"
  public static let dispatchAlreadyTerminal = "DISPATCH_ALREADY_TERMINAL"
  public static let dispatchFailed = "DISPATCH_FAILED"
  public static let dispatchAbandoned = "DISPATCH_ABANDONED"
  public static let dispatchNeedsInput = "DISPATCH_NEEDS_INPUT"
  public static let dispatchIncomplete = "DISPATCH_INCOMPLETE"
  /// `agents dispatch` refused because the pane already holds a pending dispatch.
  public static let dispatchPending = "DISPATCH_PENDING"
  /// `agents dispatch` refused because the pane's agent is working or blocked.
  public static let dispatchTargetBusy = "DISPATCH_TARGET_BUSY"
  public static let blockerUnreadable = "BLOCKER_UNREADABLE"
  public static let sessionUnresolved = "SESSION_UNRESOLVED"
  public static let resultNotFound = "RESULT_NOT_FOUND"
  public static let resultIncomplete = "RESULT_INCOMPLETE"
  public static let resultTooLarge = "RESULT_TOO_LARGE"

  // Profiles
  public static let profilesFailed = "PROFILES_FAILED"

  // Skills
  public static let skillsFailed = "SKILLS_FAILED"
  public static let skillNotFound = "SKILL_NOT_FOUND"
  public static let skillNotInstallable = "SKILL_NOT_INSTALLABLE"
  public static let installConflict = "INSTALL_CONFLICT"
  public static let bundleNotFound = "BUNDLE_NOT_FOUND"

  // Focus
  public static let focusFailed = "FOCUS_FAILED"

  // Send
  public static let emptyInput = "EMPTY_INPUT"
  public static let sendFailed = "SEND_FAILED"
  public static let waitTimeout = "WAIT_TIMEOUT"
  public static let captureUnsupported = "CAPTURE_UNSUPPORTED"

  // Key
  public static let invalidRepeat = "INVALID_REPEAT"
  public static let noActivePane = "NO_ACTIVE_PANE"
  public static let unsupportedKey = "UNSUPPORTED_KEY"
  public static let keyDeliveryFailed = "KEY_DELIVERY_FAILED"

  // Read
  public static let readFailed = "READ_FAILED"

  // Lifecycle
  public static let createFailed = "CREATE_FAILED"
  public static let closeFailed = "CLOSE_FAILED"
  public static let profileNotFound = "PROFILE_NOT_FOUND"
  public static let profileNotUnique = "PROFILE_NOT_UNIQUE"

  // Tab
  public static let tabFailed = "TAB_FAILED"

  // Pane
  public static let paneFailed = "PANE_FAILED"

  // Retired commands
  public static let handoffRetired = "HANDOFF_RETIRED"

  // Source resolution
  public static let sourceRequired = "SOURCE_REQUIRED"

  // Workflow
  public static let workflowFailed = "WORKFLOW_FAILED"
  public static let workflowNotFound = "WORKFLOW_NOT_FOUND"
  /// The file parsed or validated with errors; `details` carries the validate payload.
  public static let workflowInvalid = "WORKFLOW_INVALID"
  /// `workflow run` named a definition the user switched off.
  public static let workflowDisabled = "WORKFLOW_DISABLED"
  // Run-time codes of the workflow runner (dsl-spec §9); emitted by `workflow run/deliver` from B3 on.
  public static let runNotFound = "RUN_NOT_FOUND"
  public static let paneBusy = "PANE_BUSY"
  public static let roleMismatch = "ROLE_MISMATCH"
  public static let stepNotExpecting = "STEP_NOT_EXPECTING"
  public static let tokenRequired = "TOKEN_REQUIRED"
  public static let tokenInvalid = "TOKEN_INVALID"
  public static let outputInvalid = "OUTPUT_INVALID"
  public static let outputTooLarge = "OUTPUT_TOO_LARGE"
  public static let verdictRequired = "VERDICT_REQUIRED"
  /// A rendered `text` / pointer / `--input` value would not survive as one terminal line.
  public static let renderedTextInvalid = "RENDERED_TEXT_INVALID"
  public static let unsafePath = "UNSAFE_PATH"
  /// A rendered `launch` prompt above 32 KiB.
  public static let promptTooLarge = "PROMPT_TOO_LARGE"
  /// `agents dispatch-complete` from a pane whose pending record is a workflow activation.
  public static let workflowDeliveryRequired = "WORKFLOW_DELIVERY_REQUIRED"
  /// A socket client disconnected before its in-app workflow request completed.
  public static let requestCancelled = "REQUEST_CANCELLED"
  /// A duplicate in-app request UUID was registered; the original remains authoritative.
  public static let requestConflict = "REQUEST_CONFLICT"

  // Transport
  public static let transportFailed = "TRANSPORT_FAILED"
  public static let socketPermissionDenied = "SOCKET_PERMISSION_DENIED"
  public static let timeout = "TIMEOUT"
}
