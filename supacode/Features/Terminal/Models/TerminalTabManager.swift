import Foundation
import Observation
import ProwlCLIShared

@MainActor
@Observable
final class TerminalTabManager {
  var tabs: [TerminalTabItem] = [] {
    didSet {
      // Only when tabs actually went away: this fires on every title write too,
      // and the prune is O(n) where the guard is O(1).
      if tabs.count < oldValue.count {
        pruneTitleCoalescingState()
      }
      guard let editingTabID, !tabs.contains(where: { $0.id == editingTabID }) else { return }
      self.editingTabID = nil
    }
  }
  var selectedTabId: TerminalTabID?
  private(set) var editingTabID: TerminalTabID?

  /// Shortest gap between two live title writes for one tab.
  ///
  /// An agent TUI animates a spinner glyph inside its terminal title at roughly
  /// 10 Hz. `tabs` is observed as a whole, so one tab's frame invalidates every
  /// view reading the array — the tab bar then rebuilds every tab and AppKit
  /// re-lays the window's view tree. Sampling a spike measured that at 47% of a
  /// core in `flushTransactions` plus 32% in the CoreAnimation commit, against
  /// 2% for agent detection.
  static let liveTitleCoalescingInterval: TimeInterval = 1

  /// Bookkeeping only — a write here must never invalidate the tab bar, which is
  /// the whole point of the coalescing.
  @ObservationIgnored private var lastLiveTitleWriteAt: [TerminalTabID: Date] = [:]
  /// The most recent title held back by coalescing. A spinner that stops leaves
  /// no further change to carry it, so `flushPendingTitles` lands it instead.
  @ObservationIgnored private var pendingLiveTitles: [TerminalTabID: String] = [:]
  @ObservationIgnored private let titleFlushClock: any Clock<Duration>
  @ObservationIgnored private var pendingTitleFlushTask: Task<Void, Never>?
  @ObservationIgnored private var scheduledPendingTitleFlushDate: Date?
  @ObservationIgnored var onCoalescedTitlesFlushed: (([TerminalTabID]) -> Void)?

  init(titleFlushClock: any Clock<Duration> = ContinuousClock()) {
    self.titleFlushClock = titleFlushClock
  }

  /// Creates a tab next to the current selection. With `select: false` the
  /// selection is left untouched (background creation, e.g. a headless handoff
  /// launch) unless nothing was selected yet.
  func createTab(
    title: String,
    icon: String?,
    isTitleLocked: Bool = false,
    select: Bool = true
  ) -> TerminalTabID {
    let tab = TerminalTabItem(title: title, icon: icon, isTitleLocked: isTitleLocked)
    if let selectedTabId,
      let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabId })
    {
      tabs.insert(tab, at: selectedIndex + 1)
    } else {
      tabs.append(tab)
    }
    if select || selectedTabId == nil {
      selectedTabId = tab.id
    }
    return tab.id
  }

  func selectTab(_ id: TerminalTabID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    selectedTabId = id
  }

  /// Updates the live shell title. Returns `true` when the visible
  /// `displayTitle` actually changed (a custom title masks live updates),
  /// so callers can refresh derived UI like the Active Agents subtitle.
  @discardableResult
  func updateTitle(_ id: TerminalTabID, title: String, now: Date = Date()) -> Bool {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
    guard !tabs[index].isTitleLocked else { return false }
    // A TUI re-emits the same title constantly; skip the no-op write so it
    // doesn't invalidate the tab bar while an agent streams output. The latest
    // title still supersedes a held frame: A → B (held) → A must not flush B.
    guard tabs[index].title != title else {
      if pendingLiveTitles.removeValue(forKey: id) != nil {
        scheduleNextPendingTitleFlush(referenceDate: now)
      }
      return false
    }
    // A changed title arriving inside the interval is almost always the next
    // frame of an animation. Hold it rather than rebuilding the tab bar for it;
    // the newest one wins, so nothing queues up.
    if let lastWriteAt = lastLiveTitleWriteAt[id],
      now.timeIntervalSince(lastWriteAt) < Self.liveTitleCoalescingInterval
    {
      pendingLiveTitles[id] = title
      scheduleNextPendingTitleFlush(referenceDate: now)
      return false
    }
    let changed = writeLiveTitle(title, toTabAt: index, id: id, now: now)
    scheduleNextPendingTitleFlush(referenceDate: now)
    return changed
  }

  /// Lands any held-back title whose interval has elapsed. Returns the tabs whose
  /// visible `displayTitle` moved, so callers can refresh derived UI exactly as
  /// they would after `updateTitle`.
  ///
  /// A clock-driven trailing task calls this at the earliest pending deadline,
  /// independently of agent detection, so non-agent programs cannot strand a
  /// final title after the detection schedule goes cold.
  @discardableResult
  func flushPendingTitles(now: Date = Date()) -> [TerminalTabID] {
    guard !pendingLiveTitles.isEmpty else { return [] }
    var changed: [TerminalTabID] = []
    for (id, title) in Array(pendingLiveTitles) {
      guard let lastWriteAt = lastLiveTitleWriteAt[id],
        now.timeIntervalSince(lastWriteAt) >= Self.liveTitleCoalescingInterval
      else { continue }
      pendingLiveTitles.removeValue(forKey: id)
      guard let index = tabs.firstIndex(where: { $0.id == id }),
        !tabs[index].isTitleLocked,
        tabs[index].title != title
      else { continue }
      if writeLiveTitle(title, toTabAt: index, id: id, now: now) {
        changed.append(id)
      }
    }
    scheduleNextPendingTitleFlush(referenceDate: now)
    return changed
  }

  private func writeLiveTitle(
    _ title: String,
    toTabAt index: Int,
    id: TerminalTabID,
    now: Date
  ) -> Bool {
    pendingLiveTitles.removeValue(forKey: id)
    lastLiveTitleWriteAt[id] = now
    let previousDisplayTitle = tabs[index].displayTitle
    tabs[index].title = title
    return tabs[index].displayTitle != previousDisplayTitle
  }

  private func pruneTitleCoalescingState() {
    let liveIDs = Set(tabs.map(\.id))
    lastLiveTitleWriteAt = lastLiveTitleWriteAt.filter { liveIDs.contains($0.key) }
    pendingLiveTitles = pendingLiveTitles.filter { liveIDs.contains($0.key) }
    scheduleNextPendingTitleFlush(referenceDate: Date())
  }

  private func scheduleNextPendingTitleFlush(referenceDate: Date) {
    let nextFlushDate = pendingLiveTitles.keys.compactMap { id in
      lastLiveTitleWriteAt[id]?.addingTimeInterval(Self.liveTitleCoalescingInterval)
    }.min()
    guard let nextFlushDate else {
      pendingTitleFlushTask?.cancel()
      pendingTitleFlushTask = nil
      scheduledPendingTitleFlushDate = nil
      return
    }
    guard nextFlushDate != scheduledPendingTitleFlushDate else { return }

    pendingTitleFlushTask?.cancel()
    scheduledPendingTitleFlushDate = nextFlushDate
    let delay = max(0, nextFlushDate.timeIntervalSince(referenceDate))
    let sleep = titleFlushClock.anchoredSleep(for: .seconds(delay))
    pendingTitleFlushTask = Task { @MainActor [weak self] in
      do {
        try await sleep()
      } catch {
        return
      }
      guard let self, self.scheduledPendingTitleFlushDate == nextFlushDate else { return }
      self.pendingTitleFlushTask = nil
      self.scheduledPendingTitleFlushDate = nil
      let changed = self.flushPendingTitles(now: nextFlushDate)
      if !changed.isEmpty {
        self.onCoalescedTitlesFlushed?(changed)
      }
    }
  }

  /// Every tab the coalescing bookkeeping still holds an entry for.
  ///
  /// The dictionaries are private so a title write is only ever observable through
  /// `tabs`, which is what keeps them from invalidating the tab bar. That also hides
  /// whether closing a tab pruned them: `flushPendingTitles` skips an absent tab on
  /// its own existence guard, so it returns the same empty result either way. Without
  /// this seam a test cannot tell a working prune from a leak that grows with every
  /// tab ever closed.
  var coalescedTabIDsForTesting: Set<TerminalTabID> {
    Set(lastLiveTitleWriteAt.keys).union(pendingLiveTitles.keys)
  }

  /// Sets (or clears, when blank) the user-defined title. Returns `true` when
  /// the visible `displayTitle` actually changed.
  @discardableResult
  func setCustomTitle(_ id: TerminalTabID, title: String) -> Bool {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
    guard !tabs[index].isTitleLocked else { return false }
    let previousDisplayTitle = tabs[index].displayTitle
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    tabs[index].customTitle = trimmed.isEmpty ? nil : trimmed
    return tabs[index].displayTitle != previousDisplayTitle
  }

  func beginTabRename(_ id: TerminalTabID) {
    guard tabs.contains(where: { $0.id == id && !$0.isTitleLocked }) else { return }
    editingTabID = id
  }

  func endTabRename() {
    editingTabID = nil
  }

  /// Auto-detection write path (e.g. `CommandIconMap`). Only applies
  /// when nothing has claimed the icon slot.
  func updateIcon(_ id: TerminalTabID, icon: String?) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    guard tabs[index].iconLock == .auto else { return }
    tabs[index].icon = icon
  }

  /// User picker path. Always wins, transitioning the slot to `.user`.
  func overrideIcon(_ id: TerminalTabID, icon: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs[index].icon = icon
    tabs[index].iconLock = .user
  }

  /// "Reset to default" from the icon picker. Drops back to `.none`
  /// so the next auto-detected match can take over.
  func clearIconOverride(_ id: TerminalTabID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs[index].iconLock = .auto
  }

  /// Run Script / Custom Command write path. Pins the icon to `.script`
  /// — strong enough to block auto-detection, weak enough to yield to
  /// a user-set `.user` lock.
  func setScriptIcon(_ id: TerminalTabID, icon: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    guard tabs[index].iconLock != .user else { return }
    tabs[index].icon = icon
    tabs[index].iconLock = .script
  }

  func updateDirty(_ id: TerminalTabID, isDirty: Bool) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    // OSC-9 drives this on every progress tick; skip the no-op write so an
    // unchanged dirty flag doesn't re-render the tab bar during agent activity.
    guard tabs[index].isDirty != isDirty else { return }
    tabs[index].isDirty = isDirty
  }

  func reorderTabs(_ orderedIds: [TerminalTabID]) {
    let existingIds = Set(tabs.map(\.id))
    let incomingIds = Set(orderedIds)
    guard existingIds == incomingIds else { return }
    let map = Dictionary(
      tabs.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    tabs = orderedIds.compactMap { map[$0] }
  }

  func closeTab(_ id: TerminalTabID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs.remove(at: index)
    guard selectedTabId == id else { return }
    if index > 0 {
      selectedTabId = tabs[index - 1].id
    } else if !tabs.isEmpty {
      selectedTabId = tabs[0].id
    } else {
      selectedTabId = nil
    }
  }

  func closeOthers(keeping id: TerminalTabID) {
    tabs = tabs.filter { $0.id == id }
    selectedTabId = tabs.first?.id
  }

  func closeToRight(of id: TerminalTabID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs = Array(tabs.prefix(index + 1))
    if let selectedTabId, !tabs.contains(where: { $0.id == selectedTabId }) {
      self.selectedTabId = tabs.last?.id
    }
  }

  func closeAll() {
    tabs.removeAll()
    selectedTabId = nil
  }
}
