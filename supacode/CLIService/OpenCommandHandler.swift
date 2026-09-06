// supacode/CLIService/OpenCommandHandler.swift
// Handles `prowl open [path]` — resolves path to worktree, selects it, brings app to front.
// Response payload follows docs-ai/013-prowl-cli/contracts/open.md contract.

import AppKit
import Foundation
import ProwlCLIShared

// MARK: - Resolution

/// How the requested path was resolved against current app state.
enum OpenResolution: String, Sendable, Codable {
  /// Bare `prowl` with no path.
  case noArgument = "no-argument"
  /// Path matched an already-open root exactly.
  case exactRoot = "exact-root"
  /// Path was inside an already-open root.
  case insideRoot = "inside-root"
  /// Path was not yet managed; Prowl opened it as a new root.
  case newRoot = "new-root"
}

/// Internal result of resolving an open command against current app state.
struct OpenResolverResult: Sendable {
  let resolution: OpenResolution
  let worktreeID: String?
  let worktreeName: String?
  let worktreePath: String?
  let rootPath: String?
  let worktreeKind: String?
  let resolvedPath: String?
}

// MARK: - Contract-aligned payload

/// Success payload per docs-ai/013-prowl-cli/contracts/open.md
struct OpenCommandData: Codable {
  let invocation: String
  let requestedPath: String?
  let resolvedPath: String?
  let resolution: String
  let appLaunched: Bool
  let broughtToFront: Bool
  let createdTab: Bool
  let target: OpenTarget?

  enum CodingKeys: String, CodingKey {
    case invocation
    case requestedPath = "requested_path"
    case resolvedPath = "resolved_path"
    case resolution
    case appLaunched = "app_launched"
    case broughtToFront = "brought_to_front"
    case createdTab = "created_tab"
    case target
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(invocation, forKey: .invocation)
    if let requestedPath {
      try container.encode(requestedPath, forKey: .requestedPath)
    } else {
      try container.encodeNil(forKey: .requestedPath)
    }
    if let resolvedPath {
      try container.encode(resolvedPath, forKey: .resolvedPath)
    } else {
      try container.encodeNil(forKey: .resolvedPath)
    }
    try container.encode(resolution, forKey: .resolution)
    try container.encode(appLaunched, forKey: .appLaunched)
    try container.encode(broughtToFront, forKey: .broughtToFront)
    try container.encode(createdTab, forKey: .createdTab)
    if let target {
      try container.encode(target, forKey: .target)
    } else {
      try container.encodeNil(forKey: .target)
    }
  }
}

struct OpenTarget: Codable {
  let worktree: OpenTargetWorktree
  let tab: OpenTargetTab
  let pane: OpenTargetPane
}

struct OpenTargetWorktree: Codable {
  let id: String
  let name: String
  let path: String
  let rootPath: String
  let kind: String

  enum CodingKeys: String, CodingKey {
    case id, name, path
    case rootPath = "root_path"
    case kind
  }
}

struct OpenTargetTab: Codable {
  let id: String
  let title: String
  let cwd: String?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case cwd
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    if let cwd {
      try container.encode(cwd, forKey: .cwd)
    } else {
      try container.encodeNil(forKey: .cwd)
    }
  }
}

struct OpenTargetPane: Codable {
  let id: String
  let title: String
  let cwd: String?

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case cwd
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    if let cwd {
      try container.encode(cwd, forKey: .cwd)
    } else {
      try container.encodeNil(forKey: .cwd)
    }
  }
}

struct OpenResolvedTarget: Sendable {
  let worktreeID: String
  let worktreeName: String
  let worktreePath: String
  let worktreeRootPath: String
  let worktreeKind: String
  let tabID: String
  let tabTitle: String
  let tabCWD: String?
  let paneID: String
  let paneTitle: String
  let paneCWD: String?
}

// MARK: - Handler

final class OpenCommandHandler: CommandHandler {
  typealias Resolver = @MainActor (String?) -> OpenResolverResult
  typealias SelectAction = @MainActor (String) -> Void
  typealias AddAndOpenAction = @MainActor (URL) -> Void
  /// Creates a new tab in the given worktree and `cd`s to the specified path.
  /// Parameters: worktreeID, absolutePath.
  typealias CreateTabAtPathAction = @MainActor (String, String) -> Void
  typealias ResolveTargetAction = @MainActor (TargetSelector) -> OpenResolvedTarget?
  typealias ReadinessProvider = @MainActor () -> Bool
  typealias SleepAction = @Sendable (UInt64) async -> Void

  private let resolver: Resolver
  private let selectWorktree: SelectAction
  private let addAndOpen: AddAndOpenAction
  private let createTabAtPath: CreateTabAtPathAction
  private let resolveTarget: ResolveTargetAction
  private let isRepositoriesReady: ReadinessProvider
  private let sleep: SleepAction
  private let waitTimeoutNanoseconds: UInt64
  private let pollIntervalNanoseconds: UInt64

  init(
    resolver: @escaping Resolver,
    selectWorktree: @escaping SelectAction,
    addAndOpen: @escaping AddAndOpenAction,
    createTabAtPath: @escaping CreateTabAtPathAction = { _, _ in },
    resolveTarget: @escaping ResolveTargetAction,
    isRepositoriesReady: @escaping ReadinessProvider = { true },
    sleep: @escaping SleepAction = { nanoseconds in
      try? await Task.sleep(nanoseconds: nanoseconds)
    },
    waitTimeoutNanoseconds: UInt64 = 10_000_000_000,
    pollIntervalNanoseconds: UInt64 = 50_000_000
  ) {
    self.resolver = resolver
    self.selectWorktree = selectWorktree
    self.addAndOpen = addAndOpen
    self.createTabAtPath = createTabAtPath
    self.resolveTarget = resolveTarget
    self.isRepositoriesReady = isRepositoriesReady
    self.sleep = sleep
    self.waitTimeoutNanoseconds = waitTimeoutNanoseconds
    self.pollIntervalNanoseconds = pollIntervalNanoseconds
  }

  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    guard case .open(let input) = envelope.command else {
      return CommandResponse(
        ok: false,
        command: "open",
        schemaVersion: "prowl.cli.open.v1",
        error: CommandError(code: CLIErrorCode.invalidArgument, message: "Expected open command.")
      )
    }

    await waitForRepositoriesReadyIfNeeded()

    let appLaunched = input.appLaunched
    let result = resolver(input.path)
    let invocation = deriveInvocation(input: input)

    return await handleResolvedResult(
      result,
      input: input,
      invocation: invocation,
      appLaunched: appLaunched
    )
  }

  private func handleResolvedResult(
    _ result: OpenResolverResult,
    input: OpenInput,
    invocation: String,
    appLaunched: Bool
  ) async -> CommandResponse {
    switch result.resolution {
    case .noArgument:
      return handleNoArgument(invocation: invocation, appLaunched: appLaunched)
    case .exactRoot:
      return await handleExactRoot(
        result: result,
        input: input,
        invocation: invocation,
        appLaunched: appLaunched
      )
    case .insideRoot:
      return await handleInsideRoot(
        result: result,
        input: input,
        invocation: invocation,
        appLaunched: appLaunched
      )
    case .newRoot:
      return await handleNewRoot(
        result: result,
        input: input,
        invocation: invocation,
        appLaunched: appLaunched
      )
    }
  }

  private func handleNoArgument(invocation: String, appLaunched: Bool) -> CommandResponse {
    bringAppToFront()
    let target = makeTarget(selector: .none)
    return makeSuccess(
      invocation: invocation,
      requestedPath: nil,
      resolvedPath: nil,
      resolution: .noArgument,
      appLaunched: appLaunched,
      createdTab: false,
      target: target
    )
  }

  private func handleExactRoot(
    result: OpenResolverResult,
    input: OpenInput,
    invocation: String,
    appLaunched: Bool
  ) async -> CommandResponse {
    guard let worktreeID = result.worktreeID else {
      return makeFailure(message: "Resolved exact-root target is missing a worktree ID.")
    }
    let requestedPath = result.resolvedPath ?? input.path
    selectWorktree(worktreeID)
    bringAppToFront()

    var createdTab = false
    var target = makeTarget(selector: .worktree(worktreeID))
    if target == nil, let requestedPath {
      createTabAtPath(worktreeID, requestedPath)
      createdTab = true
      target = await waitForOpenTarget(
        selector: .worktree(worktreeID),
        preferredPaneCWD: requestedPath
      )
    }
    guard let target else {
      return makeFailure(message: "Failed to resolve the focused target for '\(worktreeID)'.")
    }
    return makeSuccess(
      invocation: invocation,
      requestedPath: input.path,
      resolvedPath: requestedPath,
      resolution: .exactRoot,
      appLaunched: appLaunched,
      createdTab: createdTab,
      target: target
    )
  }

  private func handleInsideRoot(
    result: OpenResolverResult,
    input: OpenInput,
    invocation: String,
    appLaunched: Bool
  ) async -> CommandResponse {
    guard let worktreeID = result.worktreeID else {
      return makeFailure(message: "Resolved inside-root target is missing a worktree ID.")
    }
    selectWorktree(worktreeID)
    if let subpath = result.resolvedPath ?? input.path {
      createTabAtPath(worktreeID, subpath)
    }
    bringAppToFront()
    guard
      let target = await waitForOpenTarget(
        selector: .worktree(worktreeID),
        preferredPaneCWD: result.resolvedPath ?? input.path
      )
    else {
      return makeFailure(message: "Failed to resolve the focused target for '\(worktreeID)'.")
    }
    return makeSuccess(
      invocation: invocation,
      requestedPath: input.path,
      resolvedPath: result.resolvedPath ?? input.path,
      resolution: .insideRoot,
      appLaunched: appLaunched,
      createdTab: true,
      target: target
    )
  }

  private func handleNewRoot(
    result: OpenResolverResult,
    input: OpenInput,
    invocation: String,
    appLaunched: Bool
  ) async -> CommandResponse {
    guard let path = result.resolvedPath ?? input.path else {
      return makeFailure(message: "Resolved new-root target is missing a path.")
    }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    addAndOpen(url)
    bringAppToFront()

    let finalResult = await waitForManagedResult(path: path)
    guard let worktreeID = finalResult?.worktreeID else {
      return makeFailure(message: "Failed to resolve the newly opened target for '\(path)'.")
    }

    selectWorktree(worktreeID)
    createTabAtPath(worktreeID, path)
    guard
      let target = await waitForOpenTarget(
        selector: .worktree(worktreeID),
        preferredPaneCWD: path
      )
    else {
      return makeFailure(message: "Failed to resolve the newly opened target for '\(path)'.")
    }

    return makeSuccess(
      invocation: invocation,
      requestedPath: input.path,
      resolvedPath: result.resolvedPath ?? input.path,
      resolution: .newRoot,
      appLaunched: appLaunched,
      createdTab: true,
      target: target
    )
  }

  // MARK: - Private

  private func deriveInvocation(input: OpenInput) -> String {
    if let inv = input.invocation {
      return inv
    }
    return input.path == nil ? "bare" : "open-subcommand"
  }

  private func bringAppToFront() {
    NSApplication.shared.surfaceMainWindow()
  }

  private func waitForRepositoriesReadyIfNeeded() async {
    guard !isRepositoriesReady() else { return }

    for attempt in 0..<maxPollAttempts() {
      if isRepositoriesReady() {
        return
      }
      if attempt + 1 < maxPollAttempts() {
        await sleep(pollIntervalNanoseconds)
      }
    }
  }

  private func waitForManagedResult(path: String) async -> OpenResolverResult? {
    var lastResult: OpenResolverResult?

    for attempt in 0..<maxPollAttempts() {
      let result = resolver(path)
      lastResult = result
      if result.resolution != .newRoot, result.worktreeID != nil {
        return result
      }
      if attempt + 1 < maxPollAttempts() {
        await sleep(pollIntervalNanoseconds)
      }
    }

    if let lastResult, lastResult.resolution != .newRoot, lastResult.worktreeID != nil {
      return lastResult
    }
    return nil
  }

  private func waitForOpenTarget(
    selector: TargetSelector,
    preferredPaneCWD: String? = nil
  ) async -> OpenTarget? {
    var fallbackTarget: OpenTarget?

    for attempt in 0..<maxPollAttempts() {
      if let target = makeTarget(selector: selector) {
        fallbackTarget = target
        if preferredPaneCWD == nil || target.pane.cwd == preferredPaneCWD {
          return target
        }
      }
      if attempt + 1 < maxPollAttempts() {
        await sleep(pollIntervalNanoseconds)
      }
    }

    return fallbackTarget
  }

  private func maxPollAttempts() -> Int {
    let interval = max(pollIntervalNanoseconds, 1)
    let attempts = waitTimeoutNanoseconds / interval
    return max(1, Int(attempts) + 1)
  }

  private func makeTarget(selector: TargetSelector) -> OpenTarget? {
    guard let resolved = resolveTarget(selector) else {
      return nil
    }

    return OpenTarget(
      worktree: OpenTargetWorktree(
        id: resolved.worktreeID,
        name: resolved.worktreeName,
        path: resolved.worktreePath,
        rootPath: resolved.worktreeRootPath,
        kind: resolved.worktreeKind
      ),
      tab: OpenTargetTab(
        id: resolved.tabID,
        title: resolved.tabTitle,
        cwd: resolved.tabCWD
      ),
      pane: OpenTargetPane(
        id: resolved.paneID,
        title: resolved.paneTitle,
        cwd: resolved.paneCWD
      )
    )
  }

  private func makeFailure(message: String) -> CommandResponse {
    CommandResponse(
      ok: false,
      command: "open",
      schemaVersion: "prowl.cli.open.v1",
      error: CommandError(
        code: CLIErrorCode.openFailed,
        message: message
      )
    )
  }

  // swiftlint:disable:next function_parameter_count
  private func makeSuccess(
    invocation: String,
    requestedPath: String?,
    resolvedPath: String?,
    resolution: OpenResolution,
    appLaunched: Bool,
    createdTab: Bool,
    target: OpenTarget?
  ) -> CommandResponse {
    let payload = OpenCommandData(
      invocation: invocation,
      requestedPath: requestedPath,
      resolvedPath: resolvedPath,
      resolution: resolution.rawValue,
      appLaunched: appLaunched,
      broughtToFront: true,
      createdTab: createdTab,
      target: target
    )
    do {
      return try CommandResponse(
        ok: true,
        command: "open",
        schemaVersion: "prowl.cli.open.v1",
        data: RawJSON(encoding: payload)
      )
    } catch {
      return CommandResponse(
        ok: false,
        command: "open",
        schemaVersion: "prowl.cli.open.v1",
        error: CommandError(
          code: CLIErrorCode.openFailed,
          message: "Failed to encode response."
        )
      )
    }
  }
}
