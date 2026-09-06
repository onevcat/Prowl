import Foundation
import ProwlCLIShared

struct LifecycleResolvedTarget: Sendable, Equatable {
  let resource: LifecycleResource
  let target: TabResolvedTarget
}

struct CLIProfileLaunchRequest: Sendable, Equatable {
  let resource: LifecycleResource
  let target: TabResolvedTarget
  let profile: AgentProfile
  let prompt: String?
  let path: String?
  let direction: CreatePaneDirection?
  let background: Bool
  /// Present only for a CLI prompted launch. Internal launchers opt in
  /// explicitly rather than inheriting the dispatch protocol by accident.
  let dispatchID: String?
  /// Frozen async preflight result. Nil before preparation and in legacy unit seams.
  let preparedLaunch: PreparedAgentProfileLaunch?

  init(
    resource: LifecycleResource,
    target: TabResolvedTarget,
    profile: AgentProfile,
    prompt: String?,
    path: String?,
    direction: CreatePaneDirection?,
    background: Bool,
    dispatchID: String?,
    preparedLaunch: PreparedAgentProfileLaunch? = nil
  ) {
    self.resource = resource
    self.target = target
    self.profile = profile
    self.prompt = prompt
    self.path = path
    self.direction = direction
    self.background = background
    self.dispatchID = dispatchID
    self.preparedLaunch = preparedLaunch
  }
}

private enum CLIProfileLookupError: Error {
  case notFound(String)
  case notUnique(String)
}

enum CLIProfileLaunchFailure: Error, Equatable, Sendable {
  case invalidArgument(String)
  case createFailed(String)

  static func planning(_ error: any Error, profile: AgentProfile) -> Self {
    if let runtimeError = error as? AgentRuntimeError {
      switch runtimeError {
      case .unsupportedStartIntent:
        return .invalidArgument("Agent Profile “\(profile.name)” does not support kickoff prompts.")
      case .unsupportedAgent:
        return .createFailed("Agent Profile “\(profile.name)” uses an unsupported runtime.")
      }
    }
    if let planningError = error as? AgentProfileLaunchPlanError {
      switch planningError {
      case .runtimeUnavailable:
        return .createFailed("Agent Profile “\(profile.name)” uses an unavailable runtime.")
      case .accountIsolationUnsupported:
        return .createFailed("Agent Profile “\(profile.name)” cannot use a dedicated home.")
      case .promptContainsNUL:
        return .invalidArgument("The kickoff prompt must not contain NUL bytes.")
      case .promptArgumentUnavailable:
        return .createFailed("Agent Profile “\(profile.name)” produced an invalid prompted invocation.")
      case .dispatchRequiresPrompt:
        return .createFailed("Agent Profile “\(profile.name)” produced an invalid dispatch launch.")
      case .homeEscapesBase:
        return .createFailed("Agent Profile “\(profile.name)” resolved outside the managed home directory.")
      case .homeIsSymbolicLink:
        return .createFailed("Agent Profile “\(profile.name)” has a symbolic-link managed home.")
      }
    }
    return .createFailed("Failed to prepare Agent Profile “\(profile.name)”.")
  }

  static func creation(_ error: AgentProfileLaunchError, profile: AgentProfile) -> Self {
    let message =
      switch error {
      case .homeProvisioningFailed:
        "Failed to provision the managed home for Agent Profile “\(profile.name)”."
      case .splitAnchorUnavailable, .splitCreationFailed(.anchorNotFound):
        "The split anchor for Agent Profile “\(profile.name)” is no longer available."
      case .splitCreationFailed(.insertionFailed):
        "Failed to insert the split for Agent Profile “\(profile.name)”."
      case .tabCreationFailed:
        "Failed to create a tab for Agent Profile “\(profile.name)”."
      case .launchedSurfaceMissing:
        "The tab for Agent Profile “\(profile.name)” was created without a terminal surface."
      case .hookRegistrationFailed:
        "The managed signal channel for Agent Profile “\(profile.name)” could not be registered."
      case .surfaceCreationFailed:
        "The terminal surface for Agent Profile “\(profile.name)” could not be created."
      case .preparationCancelled:
        "Agent Profile “\(profile.name)” launch preparation was cancelled."
      }
    return .createFailed(message)
  }
}

@MainActor
final class LifecycleCommandHandler: CommandHandler {
  typealias ResolveCreateTargetProvider = @MainActor (TargetSelector) -> Result<TabResolvedTarget, TargetResolverError>
  typealias ResolveCloseTargetProvider =
    @MainActor (TargetSelector) -> Result<LifecycleResolvedTarget, TargetResolverError>
  typealias CreateTabProvider = @MainActor (TabResolvedTarget, String?) -> TabResolvedTarget?
  typealias CreatePaneProvider = @MainActor (TabResolvedTarget, CreatePaneDirection) -> TabResolvedTarget?
  typealias ProfilesProvider = @MainActor () -> [AgentProfile]
  typealias PrepareProfileLaunchProvider =
    @MainActor (CLIProfileLaunchRequest) async -> Result<CLIProfileLaunchRequest, CLIProfileLaunchFailure>
  typealias ProfileLaunchProvider =
    @MainActor (CLIProfileLaunchRequest) -> Result<TabResolvedTarget, CLIProfileLaunchFailure>
  typealias CancelProfilePreparationProvider = @MainActor (CLIProfileLaunchRequest) -> Void
  typealias IssueDispatchProvider =
    @MainActor () -> Result<DispatchPendingRecord, AgentDispatchStoreError>
  typealias BindDispatchProvider =
    @MainActor (String, TabResolvedTarget) -> Result<Void, AgentDispatchStoreError>
  typealias CancelDispatchProvider = @MainActor (String) -> Void
  typealias RollbackProfileLaunchProvider = @MainActor (LifecycleResource, TabResolvedTarget) -> Void
  typealias CloseTabProvider = @MainActor (TabResolvedTarget, Bool) -> Bool
  typealias ClosePaneProvider = @MainActor (TabResolvedTarget, Bool) -> Bool

  private let resolveCreateTarget: ResolveCreateTargetProvider
  private let resolveCloseTarget: ResolveCloseTargetProvider
  private let createTab: CreateTabProvider
  private let createPane: CreatePaneProvider
  private let profiles: ProfilesProvider
  private let prepareAgentProfile: PrepareProfileLaunchProvider
  private let launchAgentProfile: ProfileLaunchProvider
  private let cancelProfilePreparation: CancelProfilePreparationProvider
  private let issueDispatch: IssueDispatchProvider
  private let bindDispatch: BindDispatchProvider
  private let cancelDispatch: CancelDispatchProvider
  private let rollbackProfileLaunch: RollbackProfileLaunchProvider
  private let closeTab: CloseTabProvider
  private let closePane: ClosePaneProvider

  init(
    resolveCreateTarget: @escaping ResolveCreateTargetProvider,
    resolveCloseTarget: @escaping ResolveCloseTargetProvider,
    createTab: @escaping CreateTabProvider,
    createPane: @escaping CreatePaneProvider,
    profiles: @escaping ProfilesProvider = { [] },
    prepareAgentProfile: @escaping PrepareProfileLaunchProvider = { .success($0) },
    launchAgentProfile: @escaping ProfileLaunchProvider = {
      _ in .failure(.createFailed("Failed to launch the Agent Profile."))
    },
    cancelProfilePreparation: @escaping CancelProfilePreparationProvider = { _ in },
    issueDispatch: @escaping IssueDispatchProvider = { .failure(.capacityExceeded) },
    bindDispatch: @escaping BindDispatchProvider = { _, _ in .failure(.notFound) },
    cancelDispatch: @escaping CancelDispatchProvider = { _ in },
    rollbackProfileLaunch: @escaping RollbackProfileLaunchProvider = { _, _ in },
    closeTab: @escaping CloseTabProvider,
    closePane: @escaping ClosePaneProvider
  ) {
    self.resolveCreateTarget = resolveCreateTarget
    self.resolveCloseTarget = resolveCloseTarget
    self.createTab = createTab
    self.createPane = createPane
    self.profiles = profiles
    self.prepareAgentProfile = prepareAgentProfile
    self.launchAgentProfile = launchAgentProfile
    self.cancelProfilePreparation = cancelProfilePreparation
    self.issueDispatch = issueDispatch
    self.bindDispatch = bindDispatch
    self.cancelDispatch = cancelDispatch
    self.rollbackProfileLaunch = rollbackProfileLaunch
    self.closeTab = closeTab
    self.closePane = closePane
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    switch envelope.command {
    case .create(let input):
      return await handleCreate(input)
    case .close(let input):
      return handleClose(input)
    default:
      return errorResponse(
        command: envelope.command.name, code: CLIErrorCode.invalidArgument, message: "Invalid command.")
    }
  }

  private func handleCreate(_ input: CreateInput) async -> CommandResponse {
    if let prompt = input.launch?.prompt {
      if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return errorResponse(
          command: "create",
          code: CLIErrorCode.emptyInput,
          message: "The kickoff prompt is empty."
        )
      }
      if prompt.contains("\0") {
        return errorResponse(
          command: "create",
          code: CLIErrorCode.invalidArgument,
          message: "The kickoff prompt must not contain NUL bytes."
        )
      }
      if prompt.utf8.count > CreateLaunchInput.maximumPromptUTF8ByteCount {
        return errorResponse(
          command: "create",
          code: CLIErrorCode.invalidArgument,
          message: "The kickoff prompt exceeds the 256 KiB UTF-8 limit."
        )
      }
    }
    switch input.resource {
    case .tab:
      return await handleCreateTab(input)
    case .pane:
      return await handleCreatePane(input)
    }
  }

  private func handleCreateTab(_ input: CreateInput) async -> CommandResponse {
    guard case .worktree = input.selector, input.direction == nil else {
      return errorResponse(
        command: "create",
        code: CLIErrorCode.invalidArgument,
        message: "create tab requires a worktree target and does not accept a direction."
      )
    }
    guard input.launch != nil || !input.background else {
      return backgroundRequiresProfileError()
    }

    let target: TabResolvedTarget
    switch resolveCreateTarget(input.selector) {
    case .success(let resolved):
      target = resolved
    case .failure(let error):
      return mapResolverError(command: "create", error: error)
    }

    let path = normalizedAllowedPath(input.path, worktreePath: target.worktreePath)
    guard input.path == nil || path != nil else {
      return errorResponse(
        command: "create",
        code: CLIErrorCode.pathNotAllowed,
        message: "Tab path must be inside the resolved worktree."
      )
    }
    if let launch = input.launch {
      return await handleProfileLaunch(
        input: input,
        launch: launch,
        target: target,
        path: path
      )
    }
    guard let createdTarget = createTab(target, path) else {
      return errorResponse(command: "create", code: CLIErrorCode.createFailed, message: "Failed to create tab.")
    }
    return success(command: "create", resource: .tab, target: createdTarget)
  }

  private func handleCreatePane(_ input: CreateInput) async -> CommandResponse {
    guard case .pane = input.selector, input.path == nil, let direction = input.direction else {
      return errorResponse(
        command: "create",
        code: CLIErrorCode.invalidArgument,
        message: "create pane requires a pane target and an explicit direction."
      )
    }
    guard input.launch != nil || !input.background else {
      return backgroundRequiresProfileError()
    }

    let anchor: TabResolvedTarget
    switch resolveCreateTarget(input.selector) {
    case .success(let resolved):
      anchor = resolved
    case .failure(let error):
      return mapResolverError(command: "create", error: error)
    }

    if let launch = input.launch {
      return await handleProfileLaunch(
        input: input,
        launch: launch,
        target: anchor,
        path: nil
      )
    }
    guard let createdTarget = createPane(anchor, direction) else {
      return errorResponse(command: "create", code: CLIErrorCode.createFailed, message: "Failed to create pane.")
    }
    return success(
      command: "create",
      resource: .pane,
      target: createdTarget,
      anchor: anchor,
      direction: direction
    )
  }

  private func handleProfileLaunch(
    input: CreateInput,
    launch: CreateLaunchInput,
    target: TabResolvedTarget,
    path: String?
  ) async -> CommandResponse {
    let profile: AgentProfile
    switch resolveProfile(launch.profile) {
    case .success(let resolved):
      profile = resolved
    case .failure(.notFound(let message)):
      return errorResponse(command: "create", code: CLIErrorCode.profileNotFound, message: message)
    case .failure(.notUnique(let message)):
      return errorResponse(command: "create", code: CLIErrorCode.profileNotUnique, message: message)
    }

    let request = CLIProfileLaunchRequest(
      resource: input.resource,
      target: target,
      profile: profile,
      prompt: launch.prompt,
      path: path,
      direction: input.direction,
      background: input.background,
      dispatchID: nil
    )
    let preparation = await preparedProfileRequest(request)
    if let response = preparation.response { return response }
    guard let preparedRequest = preparation.request else {
      return errorResponse(
        command: "create",
        code: CLIErrorCode.createFailed,
        message: "Failed to prepare the Agent Profile launch."
      )
    }

    if Task.isCancelled {
      cancelProfilePreparation(preparedRequest)
      return cancelledPreparationResponse()
    }
    let dispatchResult = issuedDispatch(prompt: launch.prompt)
    if let response = dispatchResult.response {
      cancelProfilePreparation(preparedRequest)
      return response
    }
    let dispatch = dispatchResult.record
    let pairedRequest = CLIProfileLaunchRequest(
      resource: preparedRequest.resource,
      target: preparedRequest.target,
      profile: preparedRequest.profile,
      prompt: preparedRequest.prompt,
      path: preparedRequest.path,
      direction: preparedRequest.direction,
      background: preparedRequest.background,
      dispatchID: dispatch?.id,
      preparedLaunch: preparedRequest.preparedLaunch
    )
    let createdTarget: TabResolvedTarget
    switch launchAgentProfile(pairedRequest) {
    case .success(let target):
      createdTarget = target
    case .failure(.invalidArgument(let message)):
      if let dispatch { cancelDispatch(dispatch.id) }
      cancelProfilePreparation(preparedRequest)
      return errorResponse(command: "create", code: CLIErrorCode.invalidArgument, message: message)
    case .failure(.createFailed(let message)):
      if let dispatch { cancelDispatch(dispatch.id) }
      cancelProfilePreparation(preparedRequest)
      return errorResponse(command: "create", code: CLIErrorCode.createFailed, message: message)
    }
    if let dispatch {
      switch bindDispatch(dispatch.id, createdTarget) {
      case .success:
        break
      case .failure:
        rollbackProfileLaunch(input.resource, createdTarget)
        cancelDispatch(dispatch.id)
        return errorResponse(
          command: "create",
          code: CLIErrorCode.createFailed,
          message: "The prompted Agent Profile launch could not be bound to its dispatch receipt."
        )
      }
    }
    return success(
      command: "create",
      resource: input.resource,
      target: createdTarget,
      anchor: input.resource == .pane ? target : nil,
      direction: input.direction,
      launch: LifecycleCommandLaunch(
        profileID: profile.id.uuidString,
        profileName: profile.name,
        agent: profile.runtime.agent.rawValue
      ),
      dispatch: dispatch,
      warnings: preparedRequest.preparedLaunch?.warnings
    )
  }

  private func preparedProfileRequest(
    _ request: CLIProfileLaunchRequest
  ) async -> (request: CLIProfileLaunchRequest?, response: CommandResponse?) {
    switch await prepareAgentProfile(request) {
    case .success(let prepared):
      return (prepared, nil)
    case .failure(.invalidArgument(let message)):
      return (nil, errorResponse(command: "create", code: CLIErrorCode.invalidArgument, message: message))
    case .failure(.createFailed(let message)):
      return (nil, errorResponse(command: "create", code: CLIErrorCode.createFailed, message: message))
    }
  }

  private func cancelledPreparationResponse() -> CommandResponse {
    errorResponse(
      command: "create",
      code: CLIErrorCode.createFailed,
      message: "Agent Profile launch preparation was cancelled."
    )
  }

  private func issuedDispatch(
    prompt: String?
  ) -> (record: DispatchPendingRecord?, response: CommandResponse?) {
    guard prompt != nil else { return (nil, nil) }
    switch issueDispatch() {
    case .success(let record):
      return (record, nil)
    case .failure:
      return (
        nil,
        errorResponse(
          command: "create",
          code: CLIErrorCode.dispatchCapacityExceeded,
          message: "All dispatch receipt slots are occupied by pending work; "
            + "complete or abandon a dispatch before launching another prompted task."
        )
      )
    }
  }

  private func resolveProfile(_ reference: String) -> Result<AgentProfile, CLIProfileLookupError> {
    let allProfiles = profiles()
    if let id = UUID(uuidString: reference),
      let profile = allProfiles.first(where: { $0.id == id })
    {
      guard profile.isEnabled else {
        return .failure(.notFound("Agent Profile “\(profile.name)” is disabled."))
      }
      return .success(profile)
    }
    let enabledProfiles = allProfiles.filter(\.isEnabled)
    let named = enabledProfiles.filter { $0.name == reference }
    switch named.count {
    case 1:
      return .success(named[0])
    case 0:
      return .failure(.notFound("No enabled Agent Profile matches “\(reference)”."))
    default:
      return .failure(.notUnique("Multiple enabled Agent Profiles are named “\(reference)”; use a UUID."))
    }
  }

  private func backgroundRequiresProfileError() -> CommandResponse {
    errorResponse(
      command: "create",
      code: CLIErrorCode.invalidArgument,
      message: "--background requires an Agent Profile launch."
    )
  }

  private func handleClose(_ input: CloseInput) -> CommandResponse {
    guard !input.selector.isNone else {
      return errorResponse(
        command: "close",
        code: CLIErrorCode.invalidArgument,
        message: "close requires an explicit pane or tab target."
      )
    }

    let resolved: LifecycleResolvedTarget
    switch resolveCloseTarget(input.selector) {
    case .success(let target):
      resolved = target
    case .failure(let error):
      return mapResolverError(command: "close", error: error)
    }

    let didClose =
      switch resolved.resource {
      case .tab:
        closeTab(resolved.target, input.force)
      case .pane:
        closePane(resolved.target, input.force)
      }
    guard didClose else {
      return errorResponse(
        command: "close",
        code: CLIErrorCode.closeFailed,
        message: "Failed to close \(resolved.resource.rawValue)."
      )
    }
    return success(command: "close", resource: resolved.resource, target: resolved.target)
  }

  private func normalizedAllowedPath(_ path: String?, worktreePath: String) -> String? {
    guard let path else { return nil }
    let normalizedPath = normalize(path)
    let normalizedWorktree = normalize(worktreePath)
    guard normalizedPath == normalizedWorktree || normalizedPath.hasPrefix(normalizedWorktree + "/") else {
      return nil
    }
    return normalizedPath
  }

  private func normalize(_ path: String) -> String {
    URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL
      .path(percentEncoded: false)
      .trimmingTrailingSlash()
  }

  private func success(
    command: String,
    resource: LifecycleResource,
    target: TabResolvedTarget,
    anchor: TabResolvedTarget? = nil,
    direction: CreatePaneDirection? = nil,
    launch: LifecycleCommandLaunch? = nil,
    dispatch: DispatchPendingRecord? = nil,
    warnings: [LifecycleCommandWarning]? = nil
  ) -> CommandResponse {
    do {
      return try CommandResponse(
        ok: true,
        command: command,
        schemaVersion: "prowl.cli.\(command).v1",
        data: RawJSON(
          encoding: LifecycleCommandPayload(
            resource: resource,
            anchor: anchor.map { makePayloadTarget(from: $0) },
            direction: direction,
            launch: launch,
            dispatch: dispatch,
            warnings: warnings,
            target: makePayloadTarget(from: target)
          )
        )
      )
    } catch {
      return errorResponse(command: command, code: CLIErrorCode.createFailed, message: "Failed to encode response.")
    }
  }

  private func makePayloadTarget(from target: TabResolvedTarget) -> TabTarget {
    TabTarget(from: target)
  }

  private func mapResolverError(command: String, error: TargetResolverError) -> CommandResponse {
    switch error {
    case .notFound(let message):
      errorResponse(command: command, code: CLIErrorCode.targetNotFound, message: message)
    case .notUnique(let message):
      errorResponse(command: command, code: CLIErrorCode.targetNotUnique, message: message)
    }
  }

  private func errorResponse(command: String, code: String, message: String) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: command,
      schemaVersion: "prowl.cli.\(command).v1",
      error: CommandError(code: code, message: message)
    )
  }
}

extension CreatePaneDirection {
  var terminalSplitDirection: UserCustomSplitDirection {
    switch self {
    case .right: .right
    case .left: .left
    case .upward: .top
    case .down: .down
    }
  }
}

extension String {
  fileprivate func trimmingTrailingSlash() -> String {
    var value = self
    while value.count > 1, value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }
}
