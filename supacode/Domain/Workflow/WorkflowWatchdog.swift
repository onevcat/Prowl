// supacode/Domain/Workflow/WorkflowWatchdog.swift
// The state-driven watchdog of a waiting activation (dsl-spec §10, decision G3 / H6): exact
// signals first through the activation's epoch-gated dispatch observation, the detector as a
// fallback, cancellable grace deadlines on an injected clock, and a re-read of the role's
// state at every expiry so a later event alone never decides anything.

import Foundation
import ProwlCLIShared

// MARK: - Settings and vocabulary

nonisolated struct WorkflowWatchdogSettings: Equatable, Sendable {
  /// Leaves room for the detector's 2 s heuristic stabilization plus poll/event skew;
  /// OpenCode can also fire `session.idle` twice.
  static let turnGraceFloor: Duration = .seconds(5)

  let turnGrace: Duration
  let idleGrace: Duration
  let blockedGrace: Duration
  /// How long a pane without a detected agent at arm time may take to show one (a launch
  /// that has not settled yet) before it counts as gone — the CLI wait's appearance grace.
  let appearanceGrace: Duration

  init(
    turnGrace: Duration = .seconds(15),
    idleGrace: Duration = .seconds(180),
    blockedGrace: Duration = .seconds(30),
    appearanceGrace: Duration = .seconds(10)
  ) {
    self.turnGrace = max(turnGrace, Self.turnGraceFloor)
    self.idleGrace = idleGrace
    self.blockedGrace = blockedGrace
    self.appearanceGrace = appearanceGrace
  }
}

nonisolated enum WorkflowWatchdogDeadline: String, Equatable, Sendable {
  case turnGrace
  case idleGrace
  case blockedGrace
  case appearanceGrace
  case timeout
}

/// What the role's pane looks like right now; re-read at arm time and at every expiry.
nonisolated struct WorkflowWatchdogSnapshot: Equatable, Sendable {
  /// Normalized detector state: `working`, `idle`, `done`, `blocked`, `absent`, or `gone`.
  let state: String
  let liveChannelCoversTurnEnded: Bool
  let liveChannelCoversSessionEnd: Bool
}

nonisolated enum WorkflowWatchdogInput: Equatable, Sendable {
  case armed(WorkflowWatchdogSnapshot)
  case detector(state: String)
  case detectorRemoved
  case surfaceClosed
  /// A runtime signal seen on the role's pane (`session-start` / `progress` count as activity).
  case signal(AgentSignalEvent)
  /// The activation's dispatch record reports an epoch-gated `needs-input`.
  case needsInput
  /// The activation's dispatch record reports the coalesced `turn-ended` without a delivery.
  case turnEnded
  case gone(WorkflowAgentGoneReason)
  /// The dispatch record became terminal for another reason (delivered or abandoned).
  case activationClosed
  case deadline(WorkflowWatchdogDeadline, WorkflowWatchdogSnapshot)
}

typealias WorkflowWatchdogCommands = [WorkflowWatchdogCommand]

nonisolated enum WorkflowWatchdogCommand: Equatable, Sendable {
  case schedule(WorkflowWatchdogDeadline, Duration)
  case cancel(WorkflowWatchdogDeadline)
  case emit(WorkflowWatchdogVerdict)
  case stop
}

// MARK: - Policy

/// The pure decision core. Exact mode when a `verified_live` channel covers `turn-ended`,
/// heuristic mode otherwise; one automatic nudge per activation; `working` never triggers.
nonisolated struct WorkflowWatchdogPolicy: Equatable, Sendable {
  enum Mode: Equatable, Sendable {
    case exact(coversSessionEnd: Bool)
    case heuristic
  }

  let settings: WorkflowWatchdogSettings
  let timeout: Duration?
  private(set) var mode: Mode?
  private(set) var nudged: Bool
  private(set) var stopped = false
  private var pending: Set<WorkflowWatchdogDeadline> = []
  /// Activity seen since the last `turn-ended`: a `working` detector state, `session-start`, or `progress`.
  private var sawActivity = false

  init(settings: WorkflowWatchdogSettings, timeoutSeconds: Int?, nudgedAlready: Bool) {
    self.settings = settings
    timeout = timeoutSeconds.map { .seconds($0) }
    nudged = nudgedAlready
  }

  mutating func apply(_ input: WorkflowWatchdogInput) -> WorkflowWatchdogCommands {
    guard !stopped else { return [] }
    var commands: WorkflowWatchdogCommands = []
    switch input {
    case .armed(let snapshot):
      mode =
        snapshot.liveChannelCoversTurnEnded
        ? .exact(coversSessionEnd: snapshot.liveChannelCoversSessionEnd) : .heuristic
      // The arm-time state decides on its own (dsl-spec §10): a pane that is already gone never
      // produces a later event to wait for.
      if snapshot.state == "gone" {
        finish(with: .attention(.agentGone(.paneClosed)), &commands)
        return commands
      }
      if let timeout {
        schedule(.timeout, timeout, &commands)
      }
      // No agent on a live surface: either a launch that has not settled or a process that
      // already exited to the shell. The appearance grace tells them apart at its expiry.
      if snapshot.state == "absent" {
        schedule(.appearanceGrace, settings.appearanceGrace, &commands)
      } else if mode == .heuristic {
        applyDetectorLevel(snapshot.state, &commands)
      }
    case .detector(let state):
      if state == "working" {
        sawActivity = true
      }
      if state != "absent" {
        cancel(.appearanceGrace, &commands)
      }
      if mode == .heuristic {
        applyDetectorLevel(state, &commands)
      }
    case .signal(let event):
      if event == .sessionStart || event == .progress {
        sawActivity = true
      }
    case .needsInput, .turnEnded, .detectorRemoved, .surfaceClosed, .gone, .activationClosed:
      applyEvidence(input, &commands)
    case .deadline(let deadline, let snapshot):
      pending.remove(deadline)
      applyExpiry(deadline, snapshot: snapshot, &commands)
    }
    return commands
  }

  /// Dispatch-record and lifecycle evidence: exact facts that either escalate or end the watch.
  private mutating func applyEvidence(_ input: WorkflowWatchdogInput, _ commands: inout WorkflowWatchdogCommands) {
    switch input {
    case .needsInput:
      cancel(.turnGrace, &commands)
      cancel(.idleGrace, &commands)
      commands.append(.emit(.attention(.needsInput)))
    case .turnEnded:
      sawActivity = false
      cancel(.idleGrace, &commands)
      cancel(.blockedGrace, &commands)
      schedule(.turnGrace, settings.turnGrace, &commands)
    case .detectorRemoved:
      if case .exact(coversSessionEnd: true) = mode {
        return
      }
      finish(with: .attention(.agentGone(.processGone)), &commands)
    case .surfaceClosed:
      finish(with: .attention(.agentGone(.paneClosed)), &commands)
    case .gone(let reason):
      finish(with: .attention(.agentGone(reason)), &commands)
    case .activationClosed:
      stopAll(&commands)
    case .armed, .detector, .signal, .deadline:
      break
    }
  }

  private mutating func applyDetectorLevel(_ state: String, _ commands: inout WorkflowWatchdogCommands) {
    switch state {
    case "working":
      cancel(.idleGrace, &commands)
      cancel(.blockedGrace, &commands)
    case "idle", "done":
      cancel(.blockedGrace, &commands)
      if !pending.contains(.idleGrace), !pending.contains(.turnGrace) {
        sawActivity = false
        schedule(.idleGrace, settings.idleGrace, &commands)
      }
    case "blocked":
      if !pending.contains(.blockedGrace) {
        schedule(.blockedGrace, settings.blockedGrace, &commands)
      }
    default:
      break
    }
  }

  private mutating func applyExpiry(
    _ deadline: WorkflowWatchdogDeadline, snapshot: WorkflowWatchdogSnapshot,
    _ commands: inout WorkflowWatchdogCommands
  ) {
    let active = snapshot.state == "working" || sawActivity
    switch deadline {
    case .turnGrace:
      // Activity re-arms the same grace: a freshly launched agent's first detector `working`
      // can arrive after the hook's `turn-ended`, and a watchdog that only cleared the flag
      // here would wait for a second `turn-ended` that never comes (found live, 063 B3).
      guard !active else {
        sawActivity = false
        schedule(.turnGrace, settings.turnGrace, &commands)
        return
      }
      escalate(after: .turnGrace, &commands)
    case .idleGrace:
      guard !active else {
        sawActivity = false
        // Heuristic mode re-arms from the detector's next idle level; exact mode has no such
        // trigger, so the grace re-arms itself.
        if mode != .heuristic || snapshot.state == "idle" || snapshot.state == "done" {
          schedule(.idleGrace, settings.idleGrace, &commands)
        }
        return
      }
      escalate(after: .idleGrace, &commands)
    case .blockedGrace:
      if snapshot.state == "blocked" {
        commands.append(.emit(.attention(.blocked)))
      }
    case .appearanceGrace:
      switch snapshot.state {
      case "absent":
        finish(with: .attention(.agentGone(.processGone)), &commands)
      case "gone":
        finish(with: .attention(.agentGone(.paneClosed)), &commands)
      default:
        if mode == .heuristic {
          applyDetectorLevel(snapshot.state, &commands)
        }
      }
    case .timeout:
      finish(with: .timeout, &commands)
    }
  }

  /// The one automatic nudge, then `idle_grace`, then attention. Once the nudge is spent
  /// (or the watchdog resumed after "Keep waiting"), a new turn end still earns `idle_grace`
  /// before the user is asked; only an `idle_grace` that expires idle escalates.
  private mutating func escalate(after deadline: WorkflowWatchdogDeadline, _ commands: inout WorkflowWatchdogCommands) {
    if !nudged {
      nudged = true
      commands.append(.emit(.nudge))
      schedule(.idleGrace, settings.idleGrace, &commands)
    } else if deadline == .turnGrace {
      schedule(.idleGrace, settings.idleGrace, &commands)
    } else {
      // Attention is a UI state, never a deadline: the grace timers stop, but an explicit
      // `expect.timeout` keeps counting so `on_timeout: skip | cancel` still acts (H13).
      commands.append(.emit(.attention(.idleWithoutDelivery)))
      if pending.contains(.timeout) {
        for grace in [WorkflowWatchdogDeadline.turnGrace, .idleGrace, .blockedGrace, .appearanceGrace] {
          cancel(grace, &commands)
        }
      } else {
        stopAll(&commands)
      }
    }
  }

  private mutating func schedule(
    _ deadline: WorkflowWatchdogDeadline, _ duration: Duration, _ commands: inout WorkflowWatchdogCommands
  ) {
    pending.insert(deadline)
    commands.append(.schedule(deadline, duration))
  }

  private mutating func cancel(_ deadline: WorkflowWatchdogDeadline, _ commands: inout WorkflowWatchdogCommands) {
    guard pending.remove(deadline) != nil else { return }
    commands.append(.cancel(deadline))
  }

  private mutating func finish(with verdict: WorkflowWatchdogVerdict, _ commands: inout WorkflowWatchdogCommands) {
    commands.append(.emit(verdict))
    stopAll(&commands)
  }

  private mutating func stopAll(_ commands: inout WorkflowWatchdogCommands) {
    for deadline in pending.sorted(by: { $0.rawValue < $1.rawValue }) {
      commands.append(.cancel(deadline))
    }
    pending.removeAll()
    stopped = true
    commands.append(.stop)
  }
}

// MARK: - Driver

/// Runs one activation's policy against the live streams and the injected clock. One driver per
/// waiting activation; `cancel()` tears everything down (the machine's `disarmWatchdog`).
@MainActor
final class WorkflowWatchdog {
  struct Sources {
    let observeAgent: @MainActor () -> AgentObservationStream
    let observeDispatch: @MainActor () -> AgentDispatchObservationStream?
    let snapshot: @MainActor () -> WorkflowWatchdogSnapshot
  }

  private let request: WorkflowWatchdogRequest
  private let sources: Sources
  private let clock: any Clock<Duration>
  private var policy: WorkflowWatchdogPolicy
  private var inputContinuation: AsyncStream<WorkflowWatchdogInput>.Continuation?
  private var outputContinuation: AsyncStream<WorkflowWatchdogVerdict>.Continuation?
  private var deadlineTasks: [WorkflowWatchdogDeadline: Task<Void, Never>] = [:]
  private var readerTasks: [Task<Void, Never>] = []
  private var processingTask: Task<Void, Never>?
  private(set) var isRunning = false

  init(
    request: WorkflowWatchdogRequest,
    settings: WorkflowWatchdogSettings,
    sources: Sources,
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.request = request
    self.sources = sources
    self.clock = clock
    policy = WorkflowWatchdogPolicy(
      settings: settings, timeoutSeconds: request.timeoutSeconds, nudgedAlready: request.nudgedAlready)
  }

  var ordinal: Int { request.ordinal }

  /// Starts observing; the stream finishes when the policy stops or `cancel()` is called.
  func start() -> AsyncStream<WorkflowWatchdogVerdict> {
    precondition(!isRunning, "A watchdog runs once")
    isRunning = true
    let (output, outputContinuation) = AsyncStream.makeStream(of: WorkflowWatchdogVerdict.self)
    let (inputs, inputContinuation) = AsyncStream.makeStream(of: WorkflowWatchdogInput.self)
    self.outputContinuation = outputContinuation
    self.inputContinuation = inputContinuation
    startReaders(inputContinuation)
    processingTask = Task { @MainActor [weak self] in
      guard let self else { return }
      perform(policy.apply(.armed(sources.snapshot())))
      for await input in inputs {
        if policy.stopped { break }
        perform(policy.apply(input))
      }
      finishOutput()
    }
    return output
  }

  func cancel() {
    guard isRunning else { return }
    for task in deadlineTasks.values {
      task.cancel()
    }
    deadlineTasks.removeAll()
    for task in readerTasks {
      task.cancel()
    }
    readerTasks.removeAll()
    processingTask?.cancel()
    inputContinuation?.finish()
    finishOutput()
  }

  private func finishOutput() {
    isRunning = false
    outputContinuation?.finish()
    outputContinuation = nil
  }

  private func perform(_ commands: WorkflowWatchdogCommands) {
    for command in commands {
      switch command {
      case .schedule(let deadline, let duration):
        deadlineTasks[deadline]?.cancel()
        let clock = clock
        deadlineTasks[deadline] = Task { @MainActor [weak self] in
          do {
            try await clock.sleep(for: duration)
          } catch {
            return
          }
          guard let self, !Task.isCancelled else { return }
          inputContinuation?.yield(.deadline(deadline, sources.snapshot()))
        }
      case .cancel(let deadline):
        deadlineTasks.removeValue(forKey: deadline)?.cancel()
      case .emit(let verdict):
        outputContinuation?.yield(verdict)
      case .stop:
        cancel()
      }
    }
  }

  private func startReaders(_ continuation: AsyncStream<WorkflowWatchdogInput>.Continuation) {
    let sources = sources
    readerTasks.append(
      Task { @MainActor in
        // A buffer overflow finishes the observer stream with an error; re-subscribe for as long
        // as the watchdog runs and let the fresh snapshot re-establish the level, as `agents
        // wait` does. A stream that finishes without an error (surface closed) ends the reader.
        while !Task.isCancelled {
          do {
            for try await state in sources.observeAgent() {
              continuation.yield(Self.input(for: state))
            }
            return
          } catch {
            await Task.yield()
          }
        }
      })
    guard let dispatchStream = sources.observeDispatch() else { return }
    readerTasks.append(
      Task { @MainActor in
        for await observation in dispatchStream {
          if let input = Self.input(for: observation) {
            continuation.yield(input)
          }
        }
      })
  }

  static func input(for state: ObservedAgentState) -> WorkflowWatchdogInput {
    switch state {
    case .snapshot(let snapshot):
      .detector(state: snapshot.agent.map { $0.displayState.rawValue } ?? "absent")
    case .changed(let entry):
      .detector(state: entry.displayState.rawValue)
    case .removed:
      .detectorRemoved
    case .signal(let signal):
      .signal(signal.event)
    case .surfaceClosed:
      .surfaceClosed
    }
  }

  static func input(for observation: AgentDispatchObservation) -> WorkflowWatchdogInput? {
    switch observation {
    case .snapshot(let snapshot), .changed(let snapshot):
      switch snapshot.record {
      case .pending: nil
      case .gone(_, _, _, let reason): .gone(reason == .sessionEnd ? .sessionEnded : .paneClosed)
      case .completed, .abandoned: .activationClosed
      }
    case .needsInput:
      .needsInput
    case .incomplete:
      .turnEnded
    }
  }

  /// The arm-time / expiry-time view of the role's pane from the condition evidence the CLI
  /// waits use, so the watchdog and `agents wait` agree on what "live channel" means.
  nonisolated static func snapshot(from condition: AgentConditionSnapshot) -> WorkflowWatchdogSnapshot {
    let state: String =
      if !condition.isLive {
        "gone"
      } else if let agent = condition.agent {
        agent.displayState.rawValue
      } else {
        "absent"
      }
    let live = condition.signals.channels.filter { $0.state == .verifiedLive }
    return WorkflowWatchdogSnapshot(
      state: state,
      liveChannelCoversTurnEnded: live.contains { $0.events.contains(.turnEnded) },
      liveChannelCoversSessionEnd: live.contains { $0.events.contains(.sessionEnd) })
  }
}
