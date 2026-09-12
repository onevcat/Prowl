import ComposableArchitecture
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowStepHistoryTests {
  @Test func paneHistoryMatchesSourceOrParticipantButNotAgentName() {
    let source = UUID()
    let participant = UUID()
    let index = WorkflowHistoryIndex(
      id: UUID(), name: "Review", worktreeID: "worktree", root: "/tmp", state: "completed",
      startedAt: .distantPast, finishedAt: .distantPast, sourcePaneID: source,
      participants: ["reviewer": [participant]], sessions: [:])
    #expect(index.matches(paneID: source, session: nil))
    #expect(index.matches(paneID: participant, session: nil))
    #expect(!index.matches(paneID: UUID(), session: "pi"))
    #expect(!index.matches(paneID: nil, session: nil))
  }

  @Test func sessionHistoryRequiresExactNamespacedIdentity() {
    let index = WorkflowHistoryIndex(
      id: UUID(), name: "Review", worktreeID: "worktree", root: "/tmp", state: "completed",
      startedAt: .distantPast, finishedAt: .distantPast, sourcePaneID: nil,
      participants: [:], sessions: ["reviewer": ["pi:session-1"]])
    #expect(index.matches(paneID: UUID(), session: "pi:session-1"))
    #expect(!index.matches(paneID: UUID(), session: "codex:session-1"))
  }
  @MainActor @Test func completionKeepsSelectedRunAndDetail() async throws {
    let definition = WorkflowDefinition(id: "test", name: "Test", steps: [.init(id: "end", action: .notify("done"))])
    let started = try WorkflowRunMachine.start(
      .init(
        definition: definition, runID: UUID(),
        context: .init(
          scope: .user, definitionPath: nil,
          worktree: .init(id: "wt", name: "test", branch: "main", path: "/tmp/history-tests")), bindings: [:]),
      now: { Date(timeIntervalSince1970: 1) })
    let run = started.machine.run
    var initial = WorkflowStepHistoryFeature.State()
    initial.selectedID = run.id
    initial.isPresented = true
    let store = TestStore(initialState: initial) { WorkflowStepHistoryFeature() }
    await store.send(.liveRuns([run])) {
      $0.liveRuns = [run.id: run]
      $0.entries = [WorkflowHistoryIndex(record: WorkflowRunRecord(run: run))]
      $0.directories = [run.id: run.runDirectory]
      $0.detail = WorkflowRunRecord(run: run)
    }
    #expect(store.state.isPresented)
    #expect(store.state.selectedID == run.id)
    #expect(store.state.detail?.run.status.state == "completed")
  }

  @MainActor @Test func refreshKeepsRunsCompletedAfterTheScanStarted() throws {
    let definition = WorkflowDefinition(id: "fast", name: "Fast", steps: [.init(id: "end", action: .notify("done"))])
    let started = try WorkflowRunMachine.start(
      .init(
        definition: definition, runID: UUID(),
        context: .init(
          scope: .user, definitionPath: nil,
          worktree: .init(id: "wt", name: "test", branch: "main", path: "/tmp/history-tests")), bindings: [:]),
      now: { Date(timeIntervalSince1970: 1) })
    let run = started.machine.run
    var state = WorkflowStepHistoryFeature.State()
    let reducer = WorkflowStepHistoryFeature()
    _ = reducer.reduce(into: &state, action: .refresh)
    _ = reducer.reduce(into: &state, action: .liveRuns([run]))
    _ = reducer.reduce(into: &state, action: .loaded([], [:]))
    #expect(state.entries.contains { $0.id == run.id })
    #expect(!state.removedIDs.contains(run.id))
  }

  @MainActor @Test func lateDiskDetailsDoNotReplaceLiveCompletion() throws {
    let definition = WorkflowDefinition(id: "fast", name: "Fast", steps: [.init(id: "end", action: .notify("done"))])
    let started = try WorkflowRunMachine.start(
      .init(
        definition: definition, runID: UUID(),
        context: .init(
          scope: .user, definitionPath: nil,
          worktree: .init(id: "wt", name: "test", branch: "main", path: "/tmp/history-tests")), bindings: [:]),
      now: { Date(timeIntervalSince1970: 1) })
    let run = started.machine.run
    var stale = run
    stale.status = .running
    var state = WorkflowStepHistoryFeature.State()
    state.selectedID = run.id
    state.liveRuns = [run.id: run]
    state.detail = WorkflowRunRecord(run: run)
    _ = WorkflowStepHistoryFeature().reduce(into: &state, action: .detailLoaded(run.id, WorkflowRunRecord(run: stale)))
    #expect(state.detail?.run.status.state == "completed")
  }

  @Test func outputPreviewBoundsLargeStringsAndDeepObjects() {
    let output: [String: WorkflowJSONValue] = ["result": .string(String(repeating: "a", count: 100_000))]
    #expect(WorkflowHistoryOutputField.fields(output).first?.summary.count == 201)
  }

  @MainActor @Test func refreshDoesNotResurrectRemovedTerminalRuns() async throws {
    let definition = WorkflowDefinition(id: "test", name: "Test", steps: [.init(id: "end", action: .notify("done"))])
    let started = try WorkflowRunMachine.start(
      .init(
        definition: definition, runID: UUID(),
        context: .init(
          scope: .user, definitionPath: nil,
          worktree: .init(id: "wt", name: "test", branch: "main", path: "/tmp/history-tests")), bindings: [:]),
      now: { Date(timeIntervalSince1970: 1) })
    let run = started.machine.run
    var initial = WorkflowStepHistoryFeature.State()
    initial.liveRuns = [run.id: run]
    initial.entries = [WorkflowHistoryIndex(record: WorkflowRunRecord(run: run))]
    initial.selectedID = run.id
    initial.detail = WorkflowRunRecord(run: run)
    let store = TestStore(initialState: initial) { WorkflowStepHistoryFeature() }
    store.exhaustivity = .off
    await store.send(.loaded([], [:]))
    #expect(store.state.entries.isEmpty)
    #expect(store.state.detail == nil)
    await store.send(.liveRuns([run]))
    #expect(store.state.entries.isEmpty)
  }

}

extension WorkflowStepHistoryTests {
  @MainActor @Test func deletingTheSelectedRunClearsItAndSelectsTheNextEntry() async throws {
    let definition = WorkflowDefinition(id: "test", name: "Test", steps: [.init(id: "end", action: .notify("done"))])
    func run(_ id: UUID) throws -> WorkflowRun {
      try WorkflowRunMachine.start(
        .init(
          definition: definition, runID: id,
          context: .init(
            scope: .user, definitionPath: nil,
            worktree: .init(id: "wt", name: "test", branch: "main", path: "/tmp/history-tests")), bindings: [:]),
        now: { Date(timeIntervalSince1970: 1) }
      ).machine.run
    }
    let deleted = try run(UUID(1))
    let remaining = try run(UUID(2))
    var initial = WorkflowStepHistoryFeature.State()
    initial.isPresented = true
    initial.selectedScope = .all
    initial.selectedID = deleted.id
    initial.detail = WorkflowRunRecord(run: deleted)
    initial.liveRuns = [deleted.id: deleted, remaining.id: remaining]
    initial.entries = [deleted, remaining].map { WorkflowHistoryIndex(record: WorkflowRunRecord(run: $0)) }
    initial.directories = [deleted.id: deleted.runDirectory, remaining.id: remaining.runDirectory]
    let removed = LockIsolated<[URL]>([])
    let store = TestStore(initialState: initial) {
      WorkflowStepHistoryFeature()
    } withDependencies: {
      $0[WorkflowHistoryOperations.self].delete = { directory in removed.withValue { $0.append(directory) } }
    }
    await store.send(.deleteRun(deleted.id))
    await store.receive(.runDeleted(deleted.id)) {
      $0.entries.removeAll { $0.id == deleted.id }
      $0.directories[deleted.id] = nil
      $0.liveRuns[deleted.id] = nil
      $0.removedIDs = [deleted.id]
      $0.selectedID = nil
      $0.detail = nil
    }
    await store.receive(.select(remaining.id)) {
      $0.selectedID = remaining.id
      $0.detail = WorkflowRunRecord(run: remaining)
    }
    #expect(removed.value == [deleted.runDirectory])

    // A refresh that still lists the deleted run on disk must not resurrect it.
    await store.send(.liveRuns([deleted, remaining]))
    #expect(!store.state.entries.contains { $0.id == deleted.id })
  }

  @MainActor @Test func aRunThatIsStillActiveCannotBeDeleted() async throws {
    let definition = WorkflowDefinition(
      id: "test", name: "Test",
      roles: [.init(name: "author", source: .current)],
      steps: [.init(id: "ask", action: .message(role: "author", prompt: "Hi", expect: .init()))])
    let active = try WorkflowRunMachine.start(
      .init(
        definition: definition, runID: UUID(3),
        context: .init(
          scope: .user, definitionPath: nil,
          worktree: .init(id: "wt", name: "test", branch: "main", path: "/tmp/history-tests")),
        bindings: [
          "author": .current(
            WorkflowPaneIdentity(surfaceID: UUID(4), tabID: nil, handle: "p1", displayName: "codex", agent: "codex"))
        ]),
      now: { Date(timeIntervalSince1970: 1) }
    ).machine.run
    #expect(!active.status.isTerminal)
    var initial = WorkflowStepHistoryFeature.State()
    initial.liveRuns = [active.id: active]
    initial.directories = [active.id: active.runDirectory]
    let store = TestStore(initialState: initial) {
      WorkflowStepHistoryFeature()
    } withDependencies: {
      $0[WorkflowHistoryOperations.self].delete = { _ in Issue.record("must not delete a live run") }
    }
    await store.send(.deleteRun(active.id))
  }
}
