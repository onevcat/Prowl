import Foundation
import Testing

@testable import Prowl

/// The per-surface OSC 7501 record tree (docs-ai 079): protocol lifetime rules plus the
/// local revision and arrival time that the attribution fence and the command-finished
/// cleanup rely on.
struct ProgramStatusRecordStoreTests {
  private let epoch = Date(timeIntervalSince1970: 1_000)

  private func report(
    _ state: GhosttyProgramStatusReport.State,
    id: String = "",
    app: String? = nil,
    kind: GhosttyProgramStatusReport.Kind? = nil,
    message: String? = nil
  ) -> GhosttyProgramStatusReport {
    GhosttyProgramStatusReport(state: state, kind: kind, id: id, app: app, message: message)
  }

  @Test func reportReplacesItsRecordCompletely() {
    var store = ProgramStatusRecordStore()
    store.apply(report(.working, app: "pi", message: "first"), arrivedAt: epoch)
    store.apply(report(.done), arrivedAt: epoch.addingTimeInterval(1))

    let root = store.root
    #expect(root?.state == .done)
    // A key missing from the report is missing from the record afterwards.
    #expect(root?.app == nil)
    #expect(root?.message == nil)
    #expect(root?.arrivedAt == epoch.addingTimeInterval(1))
    #expect(store.records.count == 1)
  }

  @Test func eachReportAdvancesTheRevisionAndStampsTheRecord() {
    var store = ProgramStatusRecordStore()
    #expect(store.revision == 0)
    store.apply(report(.idle), arrivedAt: epoch)
    #expect(store.revision == 1)
    store.apply(report(.working, id: "build"), arrivedAt: epoch)
    #expect(store.revision == 2)
    #expect(store.root?.revision == 1)
    #expect(store.record(id: "build")?.revision == 2)
  }

  @Test func reportWithoutAPrecedingQueryIsStored() {
    // Revision 0.3 allows reports without the probe handshake; the store never
    // requires one.
    var store = ProgramStatusRecordStore()
    store.apply(report(.working, app: "cargo"), arrivedAt: epoch)
    #expect(store.root?.state == .working)
  }

  @Test func clearRemovesTheRecordAndItsDescendantsOnly() {
    var store = ProgramStatusRecordStore()
    store.apply(report(.working), arrivedAt: epoch)
    store.apply(report(.working, id: "build"), arrivedAt: epoch)
    store.apply(report(.working, id: "build/test"), arrivedAt: epoch)
    store.apply(report(.working, id: "builder"), arrivedAt: epoch)

    store.apply(report(.clear, id: "build"), arrivedAt: epoch)

    #expect(store.record(id: "build") == nil)
    #expect(store.record(id: "build/test") == nil)
    // A sibling whose id merely starts with the cleared id is not a descendant.
    #expect(store.record(id: "builder") != nil)
    #expect(store.root != nil)
  }

  @Test func clearWithAnEmptyIDRemovesEverything() {
    var store = ProgramStatusRecordStore()
    store.apply(report(.working), arrivedAt: epoch)
    store.apply(report(.blocked, id: "child", kind: .permission), arrivedAt: epoch)
    let before = store.revision

    store.apply(report(.clear), arrivedAt: epoch)

    #expect(store.records.isEmpty)
    #expect(store.root == nil)
    #expect(store.revision == before + 1)
  }

  @Test func clearOfAMissingRecordChangesNothingButTheRevision() {
    var store = ProgramStatusRecordStore()
    store.apply(report(.working), arrivedAt: epoch)
    let before = store

    store.apply(report(.clear, id: "ghost"), arrivedAt: epoch)

    #expect(store.records == before.records)
    #expect(store.revision == before.revision + 1)
  }

  @Test func appInheritsFromTheNearestAncestorAcrossAMissingParent() {
    var store = ProgramStatusRecordStore()
    store.apply(report(.working, app: "claude-code"), arrivedAt: epoch)
    store.apply(report(.working, id: "a", app: "wrapper"), arrivedAt: epoch)
    store.apply(report(.working, id: "a/b/c"), arrivedAt: epoch)
    store.apply(report(.working, id: "x/y"), arrivedAt: epoch)

    // `a/b` does not exist; `a` is the nearest ancestor that has an app.
    #expect(store.app(of: store.record(id: "a/b/c")!) == "wrapper")
    // Neither `x/y` nor `x` has one; the root is every record's ultimate ancestor.
    #expect(store.app(of: store.record(id: "x/y")!) == "claude-code")
    #expect(store.app(of: store.root!) == "claude-code")
  }

  @Test func appIsNilWhenNoAncestorHasOne() {
    var store = ProgramStatusRecordStore()
    store.apply(report(.working, id: "a/b"), arrivedAt: epoch)
    #expect(store.app(of: store.record(id: "a/b")!) == nil)
  }

  @Test func leastRecentlyUpdatedRecordIsEvictedAtCapacity() {
    var store = ProgramStatusRecordStore()
    store.apply(report(.working, app: "cargo"), arrivedAt: epoch)
    for index in 0..<(ProgramStatusRecordStore.capacity - 1) {
      store.apply(report(.working, id: "job\(index)"), arrivedAt: epoch)
    }
    #expect(store.records.count == ProgramStatusRecordStore.capacity)
    // Touch the root so the oldest record is now `job0`, not the root.
    store.apply(report(.working, app: "cargo"), arrivedAt: epoch)

    store.apply(report(.working, id: "overflow"), arrivedAt: epoch)

    #expect(store.records.count == ProgramStatusRecordStore.capacity)
    #expect(store.record(id: "job0") == nil)
    #expect(store.record(id: "job1") != nil)
    #expect(store.record(id: "overflow") != nil)
    #expect(store.root != nil)
  }

  @Test func evictingTheRootLeavesItsChildrenInPlace() {
    // The protocol evicts the least recently updated record, nothing more. A root
    // that falls out leaves orphans that inherit no app, so they stop attributing.
    var store = ProgramStatusRecordStore()
    store.apply(report(.working, app: "cargo"), arrivedAt: epoch)
    for index in 0..<(ProgramStatusRecordStore.capacity - 1) {
      store.apply(report(.working, id: "job\(index)"), arrivedAt: epoch)
    }
    store.apply(report(.working, id: "overflow"), arrivedAt: epoch)

    #expect(store.root == nil)
    #expect(store.records.count == ProgramStatusRecordStore.capacity)
    #expect(store.app(of: store.record(id: "job5")!) == nil)
  }

  @Test func replacingAnExistingRecordAtCapacityEvictsNothing() {
    var store = ProgramStatusRecordStore()
    for index in 0..<ProgramStatusRecordStore.capacity {
      store.apply(report(.working, id: "job\(index)"), arrivedAt: epoch)
    }
    store.apply(report(.done, id: "job0"), arrivedAt: epoch)
    #expect(store.records.count == ProgramStatusRecordStore.capacity)
    #expect(store.record(id: "job0")?.state == .done)
  }

  @Test func commandFinishedDropsOnlyLiveRecordsThatExistedAtTheMark() {
    var store = ProgramStatusRecordStore()
    store.apply(report(.working), arrivedAt: epoch)  // revision 1
    store.apply(report(.blocked, id: "ask", kind: .question), arrivedAt: epoch)  // 2
    store.apply(report(.done, id: "built"), arrivedAt: epoch)  // 3
    store.apply(report(.error, id: "failed"), arrivedAt: epoch)  // 4
    store.apply(report(.idle, id: "rest"), arrivedAt: epoch)  // 5
    let mark = store.revision
    // A successor's report that arrives after the shell prompt returned is untouched.
    store.apply(report(.working, id: "successor"), arrivedAt: epoch)  // 6

    let changed = store.commandFinished(upTo: mark)

    #expect(changed)
    #expect(store.root == nil)
    #expect(store.record(id: "ask") == nil)
    #expect(store.record(id: "built")?.state == .done)
    #expect(store.record(id: "failed")?.state == .error)
    #expect(store.record(id: "rest")?.state == .idle)
    #expect(store.record(id: "successor")?.state == .working)
    #expect(store.revision == 7)
  }

  @Test func commandFinishedWithNothingToDropKeepsTheRevision() {
    var store = ProgramStatusRecordStore()
    store.apply(report(.done), arrivedAt: epoch)
    let before = store.revision
    let changed = store.commandFinished(upTo: before)
    #expect(!changed)
    #expect(store.revision == before)
    #expect(store.root?.state == .done)
  }

  @Test func kindIsKeptOnlyForBlockedRecords() {
    var store = ProgramStatusRecordStore()
    store.apply(report(.working, kind: .permission), arrivedAt: epoch)
    #expect(store.root?.kind == nil)
    store.apply(report(.blocked, kind: .auth), arrivedAt: epoch)
    #expect(store.root?.kind == .auth)
  }

  @Test func childrenExcludeTheRootAndAreOrderedByID() {
    var store = ProgramStatusRecordStore()
    store.apply(report(.working), arrivedAt: epoch)
    store.apply(report(.working, id: "b"), arrivedAt: epoch)
    store.apply(report(.working, id: "a"), arrivedAt: epoch)
    #expect(store.children.map(\.id) == ["a", "b"])
  }
}
