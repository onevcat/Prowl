import AppKit
import ComposableArchitecture
import Foundation
import ProwlCLIShared

@Reducer
struct WorkflowStepHistoryFeature {
  @ObservableState
  struct State: Equatable {
    var context = WorkflowHistoryContext()
    var selectedScope = WorkflowHistoryScope.pane
    var entries: [WorkflowHistoryIndex] = []
    var directories: [UUID: URL] = [:]
    var liveRuns: [UUID: WorkflowRun] = [:]
    var selectedID: UUID?
    var detail: WorkflowRunRecord?
    var removedIDs: Set<UUID> = []
    var scanTerminalIDs: Set<UUID>?
    var limit = 10
    var isLoading = false
    var error: String?
    var openRequest = 0
    var isPresented = false

    var filteredEntries: [WorkflowHistoryIndex] {
      entries.filter { entry in
        switch selectedScope {
        case .pane: entry.matches(paneID: context.paneID, session: context.session)
        case .worktree: entry.worktreeID == context.worktreeID
        case .all: true
        }
      }.sorted {
        let leftActive = ["running", "needs_attention"].contains($0.state)
        let rightActive = ["running", "needs_attention"].contains($1.state)
        if leftActive != rightActive { return leftActive }
        if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
        return $0.id.uuidString > $1.id.uuidString
      }
    }
    var visibleEntries: [WorkflowHistoryIndex] { Array(filteredEntries.prefix(limit)) }
    var hasMore: Bool { filteredEntries.count > limit }
    var selectedDirectory: URL? { selectedID.flatMap { directories[$0] } }
    var selectedLiveRun: WorkflowRun? {
      selectedID.flatMap { liveRuns[$0] }.flatMap { $0.status.isTerminal ? nil : $0 }
    }
  }

  enum Action: Equatable {
    case openRequested
    case context(WorkflowHistoryContext)
    case liveRuns([WorkflowRun])
    case refresh
    case loaded([WorkflowHistoryIndex], [UUID: URL])
    case failed(String)
    case setScope(WorkflowHistoryScope)
    case loadMore
    case select(UUID)
    case detailLoaded(UUID, WorkflowRunRecord)
    case setPresented(Bool)
    case output(WorkflowHistoryOutputIntent)
    /// Delete Run in the detail's More menu, after the user confirmed.
    case deleteRun(UUID)
    case runDeleted(UUID)
  }

  @Dependency(WorkflowHistoryStorageKey.self) var storage
  @Dependency(WorkflowHistoryOperations.self) var operations
  nonisolated private enum CancelID: Hashable, Sendable { case list, detail }

  var body: some Reducer<State, Action> {
    Reduce<State, Action> { state, action in
      switch action {
      case .openRequested:
        state.openRequest += 1
        return .none
      case .context(let context):
        state.context = context
        if !state.isPresented { state.selectedScope = context.paneID == nil ? .worktree : .pane }
        return .none
      case .liveRuns(let runs):
        state.liveRuns = Dictionary(
          runs.filter { !state.removedIDs.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for run in runs where !state.removedIDs.contains(run.id) {
          let index = WorkflowHistoryIndex(record: WorkflowRunRecord(run: run))
          state.entries.removeAll { $0.id == run.id }
          state.entries.append(index)
          state.directories[run.id] = run.runDirectory
          if state.selectedID == run.id { state.detail = WorkflowRunRecord(run: run) }
        }
        return .none
      case .refresh:
        guard !state.isLoading else { return .none }
        state.isLoading = true
        state.scanTerminalIDs = Set(state.liveRuns.values.filter { $0.status.isTerminal }.map(\.id))
        return .run { [storage] send in
          do {
            let result = try await Task.detached(priority: .utility) { try Self.loadIndex(storage) }.value
            await send(.loaded(result.0, result.1))
          } catch { await send(.failed(String(describing: error))) }
        }.cancellable(id: CancelID.list, cancelInFlight: true)
      case .loaded(let entries, let directories):
        state.isLoading = false
        let diskIDs = Set(entries.map(\.id))
        let candidates = state.scanTerminalIDs ?? Set(state.liveRuns.values.filter { $0.status.isTerminal }.map(\.id))
        let removed = candidates.subtracting(diskIDs)
        state.scanTerminalIDs = nil
        state.removedIDs.formUnion(removed)
        for id in removed { state.liveRuns.removeValue(forKey: id) }
        let liveIDs = Set(state.liveRuns.keys)
        state.entries =
          entries.filter { !liveIDs.contains($0.id) }
          + state.liveRuns.values.map { WorkflowHistoryIndex(record: WorkflowRunRecord(run: $0)) }
        state.directories = directories.merging(state.liveRuns.mapValues(\.runDirectory)) { _, live in live }
        if let id = state.selectedID, !diskIDs.contains(id), !liveIDs.contains(id) {
          state.detail = nil
          state.error = "This run is no longer available."
        }
        return selectDefault(&state)
      case .failed(let message):
        state.isLoading = false
        state.error = message
        return .none
      case .setScope(let scope):
        state.selectedScope = scope
        state.limit = 10
        return .none
      case .loadMore:
        state.limit += 10
        return .none
      case .select(let id):
        state.selectedID = id
        state.error = nil
        if let run = state.liveRuns[id] {
          state.detail = WorkflowRunRecord(run: run)
          return .cancel(id: CancelID.detail)
        }
        state.detail = nil
        guard let directory = state.directories[id] else { return .none }
        return .run { [storage] send in
          do {
            let record = try await Task.detached(priority: .utility) {
              let data = try storage.read(directory.appending(path: "run.json"), limit: 64 * 1024 * 1024)
              return try WorkflowRunRecord.makeDecoder().decode(WorkflowRunRecord.self, from: data)
            }.value
            await send(.detailLoaded(id, record))
          } catch { await send(.failed("Run details are unavailable: \(error)")) }
        }.cancellable(id: CancelID.detail, cancelInFlight: true)
      case .detailLoaded(let id, let detail):
        if state.selectedID == id, state.liveRuns[id] == nil { state.detail = detail }
        return .none
      case .setPresented(let presented):
        state.isPresented = presented
        if presented { return selectDefault(&state) }
        state.selectedID = nil
        state.detail = nil
        return .cancel(id: CancelID.detail)
      case .output(let intent):
        return .run { [storage, operations] send in
          do { try await WorkflowHistoryOutput.open(intent, storage: storage, operations: operations) } catch {
            await send(.failed("Could not complete the output action: \(error)"))
          }
        }
      case .deleteRun(let id):
        guard let directory = state.directories[id], state.liveRuns[id]?.status.isTerminal != false else {
          return .none
        }
        state.error = nil
        return .run { [operations] send in
          do {
            try await operations.delete(directory)
            await send(.runDeleted(id))
          } catch { await send(.failed("Could not delete the run: \(error)")) }
        }
      case .runDeleted(let id):
        state.entries.removeAll { $0.id == id }
        state.directories.removeValue(forKey: id)
        state.liveRuns.removeValue(forKey: id)
        state.removedIDs.insert(id)
        if state.selectedID == id {
          state.selectedID = nil
          state.detail = nil
        }
        return .merge(.cancel(id: CancelID.detail), selectDefault(&state))
      }
    }
  }

  private func selectDefault(_ state: inout State) -> Effect<Action> {
    guard state.isPresented, state.selectedID == nil else { return .none }
    let entries = state.filteredEntries
    guard let selected = entries.first(where: { $0.state == "needs_attention" }) ?? entries.first else { return .none }
    return .send(.select(selected.id))
  }

  nonisolated private static func loadIndex(_ storage: WorkflowHistoryStorage) throws -> (
    [WorkflowHistoryIndex], [UUID: URL]
  ) {
    var entries: [WorkflowHistoryIndex] = []
    var directories: [UUID: URL] = [:]
    for directory in try storage.directories() {
      guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
      let index: WorkflowHistoryIndex?
      if let data = try? storage.read(directory.appending(path: WorkflowHistoryIndex.fileName)),
        let decoded = try? JSONDecoder().decode(WorkflowHistoryIndex.self, from: data), decoded.id == id
      {
        index = decoded
      } else if let data = try? storage.read(directory.appending(path: "run.json")),
        let record = try? WorkflowRunRecord.makeDecoder().decode(WorkflowRunRecord.self, from: data),
        record.run.id == id
      {
        index = WorkflowHistoryIndex(record: record)
      } else if let data = try? storage.read(directory.appending(path: "history.json")),
        let metadata = try? JSONDecoder().decode(WorkflowHistoryMetadata.self, from: data), metadata.id == id
      {
        index = WorkflowHistoryIndex(
          id: id, name: metadata.name, worktreeID: metadata.root, root: metadata.root,
          state: metadata.state, startedAt: metadata.startedAt, finishedAt: metadata.finishedAt,
          sourcePaneID: nil, participants: [:], sessions: [:])
      } else {
        index = WorkflowHistoryIndex(
          id: id, name: "Unavailable Run", worktreeID: "", root: "", state: "unknown",
          startedAt: .distantPast, finishedAt: nil, sourcePaneID: nil, participants: [:], sessions: [:])
      }
      if let index {
        entries.append(index)
        directories[id] = directory
      }
    }
    return (entries, directories)
  }
}
