// supacode/Domain/Workflow/WorkflowRunStore.swift
// Personal run directories contain `run.json`,
// an append-only `log.md`, materialized instructions and skills, and versioned deliveries with an
// atomically replaced latest view. Every path is built from validated slugs and the run UUID
// under the same physical containment gate as profile homes.

import Darwin
import Foundation
import ProwlCLIShared

// MARK: - run.json

nonisolated struct WorkflowRunRecordInvocation: Codable, Equatable, Sendable {
  let ordinal: Int
  let step: String
  let iteration: Int?
  let role: String
  let kind: WorkflowInvocationKind
  let instructionPath: String?
  let resources: [String: String]?
  let skill: String?
  let activation: WorkflowRunRecordActivation?
  let startedAt: Date
  let endedAt: Date?

  enum CodingKeys: String, CodingKey {
    case ordinal
    case step
    case iteration
    case role
    case kind
    case instructionPath = "instruction_path"
    case resources
    case skill
    case activation
    case startedAt = "started_at"
    case endedAt = "ended_at"
  }
}

nonisolated struct WorkflowRunRecordActivation: Codable, Equatable, Sendable {
  let dispatchID: String?
  let state: WorkflowActivationState
  let output: String

  enum CodingKeys: String, CodingKey {
    case dispatchID = "dispatch_id"
    case state
    case output
  }
}

nonisolated struct WorkflowRunRecordInfo: Codable, Equatable, Sendable {
  let id: UUID
  let workflowID: String
  let workflowName: String
  let scope: WorkflowRunScope
  let definitionPath: String?
  let status: WorkflowRunRecord.Status
  let startedAt: Date
  let updatedAt: Date
  let finishedAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case workflowID = "workflow_id"
    case workflowName = "workflow_name"
    case scope
    case definitionPath = "definition_path"
    case status
    case startedAt = "started_at"
    case updatedAt = "updated_at"
    case finishedAt = "finished_at"
  }
}

/// The persisted snapshot of a run (decision H5 of docs-ai 063.007). Carries profile UUID/name
/// and agent tokens, pane ids, dispatch ids, and paths — never delivery tokens, environment
/// values, extra arguments, home paths, or credentials. Readers tolerate unknown keys.
nonisolated struct WorkflowRunRecord: Codable, Equatable, Sendable {
  static let currentVersion = 1
  static let fileName = "run.json"

  struct Attention: Codable, Equatable, Sendable {
    let reason: String
    let message: String
    let actions: [WorkflowAttentionAction]
    let step: String
    let role: String?
    let ordinal: Int?
    /// Issue codes of a provisional delivery (`delivery_issues` only).
    let issues: [String]?
  }

  struct Status: Codable, Equatable, Sendable {
    let state: String
    let step: String?
    let dependent: String?
    let attention: Attention?
  }

  struct Binding: Codable, Equatable, Sendable {
    let source: WorkflowRoleSource
    let profile: WorkflowProfileBinding?
    let pane: WorkflowPaneIdentity?
  }

  struct Step: Codable, Equatable, Sendable {
    let id: String
    let iteration: Int?
    let state: WorkflowStepState
    let ordinal: Int?
  }

  let version: Int
  let run: WorkflowRunRecordInfo
  let worktree: WorkflowRunWorktree
  /// Input names only: values are workflow-defined text and may be anything the user typed.
  let inputs: [String]
  let bindings: [String: Binding]
  let invocations: [WorkflowRunRecordInvocation]
  let deliveries: [String: WorkflowDeliveryRecord]
  let actions: [String: [String: WorkflowJSONValue]]
  let state: [String: WorkflowJSONValue]?
  let actionAttempts: [String: Int]?
  let skippedOutputs: [String: String]
  let steps: [Step]

  enum CodingKeys: String, CodingKey {
    case version
    case run
    case worktree
    case inputs
    case bindings
    case invocations
    case deliveries
    case actions
    case state
    case actionAttempts = "action_attempts"
    case skippedOutputs = "skipped_outputs"
    case steps
  }

  init(run: WorkflowRun) {
    version = Self.currentVersion
    self.run = WorkflowRunRecordInfo(
      id: run.id,
      workflowID: run.definition.id,
      workflowName: run.definition.name,
      scope: run.context.scope,
      definitionPath: run.context.definitionPath,
      status: Status(run.status),
      startedAt: run.startedAt,
      updatedAt: run.updatedAt,
      finishedAt: run.finishedAt
    )
    worktree = run.context.worktree
    inputs = run.inputs.keys.sorted()
    bindings = run.bindings.mapValues { Binding(source: $0.source, profile: $0.profile, pane: $0.pane) }
    invocations = run.invocations.map { invocation in
      WorkflowRunRecordInvocation(
        ordinal: invocation.ordinal,
        step: invocation.stepID,
        iteration: invocation.iteration,
        role: invocation.role,
        kind: invocation.kind,
        instructionPath: invocation.instructionPath,
        resources: invocation.content?.resources.mapValues { String($0.dropFirst(run.runDirectory.path.count + 1)) },
        skill: invocation.content?.skill,
        activation: invocation.activation.map {
          WorkflowRunRecordActivation(dispatchID: $0.dispatchID, state: $0.state, output: $0.deliveryName)
        },
        startedAt: invocation.startedAt,
        endedAt: invocation.endedAt
      )
    }
    deliveries = run.deliveries
    actions = run.actionOutputs
    state = run.controlCursor?.state.values
    actionAttempts = run.actionAttempts
    skippedOutputs = run.skippedOutputs
    steps = run.stepRecords.map { Step(id: $0.stepID, iteration: $0.iteration, state: $0.state, ordinal: $0.ordinal) }
  }

  private init(interrupting record: WorkflowRunRecord, at date: Date) {
    version = record.version
    run = WorkflowRunRecordInfo(
      id: record.run.id,
      workflowID: record.run.workflowID,
      workflowName: record.run.workflowName,
      scope: record.run.scope,
      definitionPath: record.run.definitionPath,
      status: Status(.interrupted),
      startedAt: record.run.startedAt,
      updatedAt: date,
      finishedAt: date
    )
    worktree = record.worktree
    inputs = record.inputs
    bindings = record.bindings
    invocations = record.invocations
    deliveries = record.deliveries
    actions = record.actions
    state = record.state
    actionAttempts = record.actionAttempts
    skippedOutputs = record.skippedOutputs
    steps = record.steps
  }

  func interrupted(at date: Date) -> WorkflowRunRecord {
    WorkflowRunRecord(interrupting: self, at: date)
  }

  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

extension WorkflowRunRecord.Status {
  nonisolated init(_ status: WorkflowRunStatus) {
    switch status {
    case .running:
      self.init(state: "running", step: nil, dependent: nil, attention: nil)
    case .needsAttention(let attention):
      self.init(
        state: "needs_attention", step: attention.stepID, dependent: nil,
        attention: WorkflowRunRecord.Attention(
          reason: attention.reason.code, message: attention.message, actions: attention.actions,
          step: attention.stepID, role: attention.role, ordinal: attention.ordinal,
          issues: attention.reason.issueCodes))
    case .completed:
      self.init(state: "completed", step: nil, dependent: nil, attention: nil)
    case .cancelled:
      self.init(state: "cancelled", step: nil, dependent: nil, attention: nil)
    case .skipped(let step, let dependent):
      self.init(state: "skipped", step: step, dependent: dependent, attention: nil)
    case .iterationLimitReached:
      self.init(state: "iteration_limit_reached", step: nil, dependent: nil, attention: nil)
    case .interrupted:
      self.init(state: "interrupted", step: nil, dependent: nil, attention: nil)
    }
  }

  nonisolated var isTerminal: Bool {
    ["completed", "cancelled", "skipped", "iteration_limit_reached", "interrupted"].contains(state)
  }
}

extension WorkflowAttentionReason {
  nonisolated var issueCodes: [String]? {
    if case .deliveryIssues(let issues) = self { return issues.map(\.code) }
    return nil
  }

  nonisolated var code: String {
    switch self {
    case .needsInput: "needs_input"
    case .idleWithoutDelivery: "idle_without_delivery"
    case .blocked: "blocked"
    case .agentGone(let reason): "agent_gone:\(reason.rawValue)"
    case .injectionFailed(let failure):
      switch failure {
      case .roleBusy: "injection_failed:role_busy"
      case .roleBlocked: "injection_failed:role_blocked"
      case .surfaceMissing: "injection_failed:surface_missing"
      case .insertFailed: "injection_failed:insert_failed"
      case .submitFailed: "injection_failed:submit_failed"
      case .activationUnavailable: "injection_failed:activation_unavailable"
      }
    case .launchFailed: "launch_failed"
    case .renderedTextInvalid: "rendered_text_invalid"
    case .actionFailed: "action_failed"
    case .persistFailed: "persist_failed"
    case .deliveryIssues: "delivery_issues"
    case .timeout: "timeout"
    }
  }
}

/// The restart scan's view of a record: enough to tell version and state, nothing else.
nonisolated private struct WorkflowRunRecordHeaderStatus: Decodable {
  let state: String
}

nonisolated private struct WorkflowRunRecordHeader: Decodable {
  struct Run: Decodable {
    let status: WorkflowRunRecordHeaderStatus
  }

  let version: Int
  let run: Run

  var isTerminal: Bool { run.status.state != "running" && run.status.state != "needs_attention" }
}

// MARK: - Store

nonisolated enum WorkflowRunStoreError: Error, Equatable, Sendable {
  /// A path component is not a validated slug, or the resolved path leaves the runs directory.
  case unsafePath(String)
  /// The run directory or one of its subdirectories is a symbolic link.
  case symbolicLink(String)
  case unreadableRecord(String)
  case skillMissing(String)
}

/// Result of the launch-time scan for runs a previous app instance left behind.
nonisolated struct WorkflowInterruptedRuns: Equatable, Sendable {
  let interrupted: [UUID]
  /// Run directories whose `run.json` could not be read or decoded; left untouched.
  let unreadable: [String]
}

nonisolated struct WorkflowRunStore: Sendable {
  static let logFileName = "log.md"

  let rootURL: URL
  let storage: WorkflowHistoryStorage
  let fixedDirectory: URL?

  init(rootURL: URL, directory: URL? = nil, storage: WorkflowHistoryStorage = .configured) {
    self.rootURL = rootURL.standardizedFileURL
    self.storage = storage
    fixedDirectory = directory
  }

  var runsDirectory: URL { storage.baseURL.appending(path: storage.rootKey(rootURL)) }

  func directory(for runID: UUID) -> URL {
    if let fixedDirectory { return fixedDirectory }
    if let existing = try? storage.find(runID) { return existing }
    return storage.directory(root: rootURL, createdAt: Date(), runID: runID)
  }

  // MARK: Layout

  /// Creates only personal storage. No project-local pointer or ignore file is needed.
  func ensureLayout(runID: UUID) throws {
    let runDirectory = directory(for: runID)
    try storage.prepare(runDirectory)
    for name in ["instructions", "deliveries", "skills"] {
      try storage.prepare(runDirectory.appending(path: name))
    }
  }

  func containedRunDirectory(runID: UUID) throws -> URL {
    let runDirectory = directory(for: runID)
    guard UUID(uuidString: runDirectory.lastPathComponent) == runID else {
      throw WorkflowRunStoreError.unsafePath(runDirectory.path)
    }
    try storage.validate(runDirectory)
    return runDirectory
  }

  // MARK: run.json

  func writeRecord(_ record: WorkflowRunRecord) throws {
    let runDirectory = try containedRunDirectory(runID: record.run.id)
    let data = try WorkflowRunRecord.makeEncoder().encode(record)
    try requireNotSymbolicLink(runDirectory.appending(path: WorkflowRunRecord.fileName, directoryHint: .notDirectory))
    let metadata = WorkflowHistoryMetadata(
      id: record.run.id, name: record.run.workflowName, root: record.worktree.path,
      state: record.run.status.state, startedAt: record.run.startedAt, finishedAt: record.run.finishedAt)
    try metadata.write(record: data, directory: runDirectory, storage: storage)
  }

  func readRecord(runID: UUID) throws -> WorkflowRunRecord {
    let runDirectory = try containedRunDirectory(runID: runID)
    let url = runDirectory.appending(path: WorkflowRunRecord.fileName, directoryHint: .notDirectory)
    try requireNotSymbolicLink(url)
    return try Self.decodeRecord(at: url)
  }

  private static func decodeRecord(at url: URL) throws -> WorkflowRunRecord {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw WorkflowRunStoreError.unreadableRecord(url.path(percentEncoded: false))
    }
    do {
      return try WorkflowRunRecord.makeDecoder().decode(WorkflowRunRecord.self, from: data)
    } catch {
      throw WorkflowRunStoreError.unreadableRecord(url.path(percentEncoded: false))
    }
  }

  // MARK: log.md

  /// Appends through an `O_NOFOLLOW` descriptor: a `log.md` swapped for a symbolic link is
  /// refused instead of followed. The descriptor must also have a single hard link.
  func appendLog(runID: UUID, line: String, now: Date) throws {
    let runDirectory = try containedRunDirectory(runID: runID)
    let logURL = runDirectory.appending(path: Self.logFileName, directoryHint: .notDirectory)
    let path = logURL.path(percentEncoded: false)
    try requireNotSymbolicLink(logURL)
    let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      let code = errno
      if code == ELOOP { throw WorkflowRunStoreError.symbolicLink(path) }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var statistics = stat()
    guard fstat(descriptor, &statistics) == 0, (statistics.st_mode & S_IFMT) == S_IFREG,
      statistics.st_nlink == 1
    else {
      throw WorkflowRunStoreError.unsafePath(path)
    }
    var entry = ""
    if statistics.st_size == 0 {
      entry += "# Workflow run \(runID.uuidString)\n\n"
    }
    entry += "- \(Self.timestamp(now))  \(line.replacing("\n", with: " "))\n"
    try handle.write(contentsOf: Data(entry.utf8))
  }

  // MARK: Instructions and deliveries

  @discardableResult
  func writeInstruction(runID: UUID, stepID: String, ordinal: Int, text: String) throws -> URL {
    let runDirectory = try containedRunDirectory(runID: runID)
    guard WorkflowSchema.isSlug(stepID), ordinal > 0 else { throw WorkflowRunStoreError.unsafePath(stepID) }
    let url = WorkflowRunPaths.instructionURL(runDirectory: runDirectory, stepID: stepID, ordinal: ordinal)
    try requireNotSymbolicLink(url.deletingLastPathComponent())
    try requireNotSymbolicLink(url)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// Writes `deliveries/<name>.<ordinal>.md` and replaces `deliveries/<name>.md` atomically
  /// (temp file + rename), so a reader never sees a partially written latest view.
  @discardableResult
  func writeOutput(runID: UUID, name: String, ordinal: Int, body: String) throws -> (versioned: URL, latest: URL) {
    let runDirectory = try containedRunDirectory(runID: runID)
    guard WorkflowSchema.isSlug(name), ordinal > 0 else { throw WorkflowRunStoreError.unsafePath(name) }
    let versioned = WorkflowRunPaths.deliveryURL(runDirectory: runDirectory, name: name, ordinal: ordinal)
    let latest = WorkflowRunPaths.deliveryURL(runDirectory: runDirectory, name: name, ordinal: nil)
    try requireNotSymbolicLink(versioned.deletingLastPathComponent())
    try requireNotSymbolicLink(versioned)
    try requireNotSymbolicLink(latest)
    let data = Data(body.utf8)
    try data.write(to: versioned, options: .atomic)
    let temporary = latest.deletingLastPathComponent()
      .appending(path: ".\(name).md.\(UUID().uuidString).tmp", directoryHint: .notDirectory)
    try data.write(to: temporary)
    guard rename(temporary.path(percentEncoded: false), latest.path(percentEncoded: false)) == 0 else {
      let code = errno
      try? FileManager.default.removeItem(at: temporary)
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return (versioned, latest)
  }

  // MARK: Skills

  /// Freezes the assigned bundled skill for scoped CLI retrieval.
  @discardableResult
  func materializeSkill(runID: UUID, skill: BundledSkill) throws -> URL {
    let runDirectory = try containedRunDirectory(runID: runID)
    guard WorkflowSchema.isWorkflowID(skill.id) else { throw WorkflowRunStoreError.unsafePath(skill.id) }
    let fileManager = FileManager.default
    let skillFile = skill.directoryURL.appending(path: "SKILL.md", directoryHint: .notDirectory)
    guard fileManager.fileExists(atPath: skillFile.path(percentEncoded: false)) else {
      throw WorkflowRunStoreError.skillMissing(skill.id)
    }
    let destination = WorkflowRunPaths.skillDirectory(runDirectory: runDirectory, skillID: skill.id)
    try requireNotSymbolicLink(destination.deletingLastPathComponent())
    if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: skill.directoryURL, to: destination)
    return destination
  }

  // MARK: Restart

  /// V1 has no resume: every run left `running` / `needs_attention` on disk becomes
  /// `interrupted`. Only a small header (`version`, `run.status.state`) is read before a run is
  /// selected, so a record of another version is left alone; a v1 record that cannot be decoded
  /// or a run directory that fails the containment gate is reported and left untouched.
  func markInterruptedRuns(now: () -> Date, allRoots: Bool = false) throws -> WorkflowInterruptedRuns {
    let coordination = try storage.coordinate()
    defer { coordination.close() }
    let entries = try storage.directories().filter {
      allRoots
        || $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == storage.rootKey(rootURL)
    }
    var interrupted: [UUID] = []
    var unreadable: [String] = []
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let occupancy: WorkflowHistoryLock
      do { occupancy = try storage.occupy(entry) } catch WorkflowHistoryError.occupied { continue } catch {
        unreadable.append(entry.path)
        continue
      }
      defer { occupancy.close() }
      guard let runID = UUID(uuidString: entry.lastPathComponent) else { continue }
      let runDirectory: URL
      do {
        runDirectory = try containedRunDirectory(runID: runID)
      } catch {
        unreadable.append(AgentProfileLaunchPlanner.pathString(directory(for: runID)))
        continue
      }
      let recordURL = runDirectory.appending(path: WorkflowRunRecord.fileName, directoryHint: .notDirectory)
      guard FileManager.default.fileExists(atPath: recordURL.path(percentEncoded: false)) else { continue }
      let recordPath = recordURL.path(percentEncoded: false)
      guard let header = try? Self.decodeHeader(at: recordURL) else {
        unreadable.append(recordPath)
        continue
      }
      guard header.version == WorkflowRunRecord.currentVersion,
        ["running", "needs_attention"].contains(header.run.status.state)
      else { continue }
      let record: WorkflowRunRecord
      do {
        record = try Self.decodeRecord(at: recordURL)
      } catch {
        unreadable.append(recordPath)
        continue
      }
      guard record.run.id == runID else {
        unreadable.append(recordPath)
        continue
      }
      let timestamp = now()
      try writeRecord(record.interrupted(at: timestamp))
      try appendLog(runID: runID, line: "Run marked interrupted at app launch (no resume in V1).", now: timestamp)
      interrupted.append(runID)
    }
    return WorkflowInterruptedRuns(interrupted: interrupted, unreadable: unreadable)
  }

  private static func decodeHeader(at url: URL) throws -> WorkflowRunRecordHeader {
    try requireNotSymbolicLinkStatic(url)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(WorkflowRunRecordHeader.self, from: data)
  }

  // MARK: Helpers

  private func requireNotSymbolicLink(_ url: URL) throws {
    try Self.requireNotSymbolicLinkStatic(url)
  }

  private static func requireNotSymbolicLinkStatic(_ url: URL) throws {
    let path = AgentProfileLaunchPlanner.pathString(url)
    if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      attributes[.type] as? FileAttributeType == .typeSymbolicLink
    {
      throw WorkflowRunStoreError.symbolicLink(path)
    }
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}
