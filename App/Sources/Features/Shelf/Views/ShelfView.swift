import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

private let shelfLogger = SupaLogger("Shelf")

/// Root view for Shelf presentation mode.
///
/// Phase 3 layout: three horizontal segments — a left stack of passed
/// spines (each showing its book's tabs), the currently open book's
/// terminal area, and a right stack of upcoming spines. Clicking a tab
/// on any spine opens that book (when different) and selects that tab.
/// Animations and the ⌘-held digit overlay are layered in subsequent
/// phases.
struct ShelfView: View {
  let store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let createTab: () -> Void

  /// Mirrors the Ghostty `background-opacity` setting so the Shelf can
  /// honor the same window transparency as normal view mode. A previous
  /// plain `.background(.background)` defeated transparency entirely by
  /// stamping an opaque layer behind every child — including the
  /// terminal surface and empty-state area.
  @Environment(\.surfaceBackgroundOpacity) private var surfaceBackgroundOpacity
  @Shared(.repositoryAppearances) private var repositoryAppearances
  /// Drives the chrome tint mode / custom color and the Shelf spine tint
  /// preferences.
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    // Body-invocation counter. The @ViewBuilder getter rules out a
    // `defer`-based interval, but a fire-and-forget event marker is a
    // simple expression and has no impact on the rendered tree. Each
    // marker corresponds to one full body re-evaluation — useful for
    // sanity-checking how often the root re-renders during animation.
    let _ = shelfLogger.event("ShelfView.body")
    let state = store.state
    let books = state.orderedShelfBooks(customTitles: state.repositoryCustomTitles)
    let openBook = state.openShelfBook(in: books)
    let openBookID = openBook?.id
    let openIndex = openBook.flatMap { book in
      books.firstIndex(where: { $0.id == book.id })
    }
    let activeAgentEntriesByWorktreeID =
      settingsFile.global.showActiveAgentStatusInShelf
      ? Dictionary(grouping: state.activeAgents.entries) { entry in entry.worktreeID }
      : [:]
    // Color identity of the open book's repo (nil ⇒ neutral surface). Shared
    // by the spine fill and the toolbar band so they read as one "L".
    let openColor = openBook.flatMap { repositoryAppearances[$0.repositoryID]?.color }
    // Chrome band fill for the toolbar (top) and nav (leading), honoring the
    // user's window tint mode. Only shown when a book is open; an empty
    // shelf keeps its bare chrome.
    let chromeFill =
      openBook == nil
      ? nil
      : WindowChromeTint.fill(
        mode: settingsFile.global.windowTintMode,
        customColor: settingsFile.global.windowTintCustomColor.color,
        repositoryColor: openColor
      )

    HStack(spacing: 0) {
      ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
        spine(
          book: book,
          index: index,
          openIndex: openIndex,
          activeAgentEntries: activeAgentEntriesByWorktreeID[book.id] ?? []
        )
        if book.id == openBookID {
          openBookArea(for: book, state: state)
        }
      }
      if openBook == nil {
        emptyOpenArea()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor).opacity(surfaceBackgroundOpacity))
    // Tint the toolbar (top) and nav (leading) chrome. The bands bleed up
    // under the titlebar and left under the floating glass sidebar, so once
    // the glass blends the leading band in, the nav panel, the open spine,
    // and the toolbar all read as one continuous color.
    .windowChromeTint(chromeFill, edges: [.top, .leading])
    .overlay {
      ShelfSwipeEventMonitor(isEnabled: !books.isEmpty) { action in
        switch action {
        case .nextBook:
          store.send(.selectNextShelfBook)
        case .previousBook:
          store.send(.selectPreviousShelfBook)
        case .nextTab:
          store.send(.selectNextWorktree)
        case .previousTab:
          store.send(.selectPreviousWorktree)
        }
      }
      .accessibilityHidden(true)
      .allowsHitTesting(false)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // Animate on every openBookID change — covers both Shelf-originated
    // book switches (which also set their own TCA animation) and
    // left-nav-originated switches, so the spine flow is consistent
    // regardless of entry point.
    .animation(.easeInOut(duration: 0.2), value: openBookID)
  }

  @ViewBuilder
  private func spine(
    book: ShelfBook,
    index: Int,
    openIndex: Int?,
    activeAgentEntries: [ActiveAgentEntry]
  ) -> some View {
    let distance = openIndex.map { abs(index - $0) }
    let open = index == openIndex
    ShelfSpineView(
      book: book,
      isOpen: open,
      distanceFromOpen: distance,
      terminalState: terminalManager.stateIfExists(for: book.id),
      activeAgentEntries: activeAgentEntries,
      tintFallback: settingsFile.global.shelfSpineTintFallback,
      followsRepositoryColor: settingsFile.global.shelfSpineTintFollowsRepositoryColor,
      onOpenBook: { openBook(book, selectingTab: nil) },
      onSelectTab: { tabID in openBook(book, selectingTab: tabID) },
      onSelectAgent: { agentID in
        store.send(.activeAgents(.entryTapped(agentID)))
      },
      onNewTab: {
        // On a closed spine, `+` doubles as "pull this book out and
        // start a fresh tab". Sequencing is fine because TCA runs
        // reducers synchronously — `newTerminal` will observe the
        // new `selectedTerminalWorktree` set by `selectWorktree`.
        switchToBookIfNeeded(book)
        createTab()
      },
      onSplitVertical: open ? { performSplit(direction: "new_split:right") } : nil,
      onSplitHorizontal: open ? { performSplit(direction: "new_split:down") } : nil,
      closeMenuTitle: closeMenuTitle(for: book),
      onCloseBook: { closeBook(book) },
      onOpenRepositorySettings: {
        store.send(.repositoryManagement(.openRepositorySettings(book.repositoryID)))
      }
    )
  }

  /// Dispatch the open-book action only when `book` isn't already the open
  /// one — idempotent helper for taps that imply a book change.
  ///
  /// No `animation:` is passed to `store.send` because the visible
  /// spine-flow animation is already driven by the view-level
  /// `.animation(.easeInOut(duration: 0.2), value: openBookID)` modifier
  /// on the root container — wrapping the dispatch in another animation
  /// transaction would double-run layout / transition machinery for the
  /// same change.
  private func switchToBookIfNeeded(_ book: ShelfBook) {
    guard !isOpen(book) else { return }
    shelfLogger.event("BookClick.NewTabSpine")
    switch book.kind {
    case .worktree:
      store.send(.selectWorktree(book.id, focusTerminal: true))
    case .plainFolder:
      store.send(.selectRepository(book.repositoryID))
    }
  }

  private func performSplit(direction: String) {
    guard let openID = store.state.openShelfBookID,
      let state = terminalManager.stateIfExists(for: openID)
    else { return }
    _ = state.performBindingActionOnFocusedSurface(direction)
  }

  /// "Close Worktree / Close Folder" context action. Equivalent to
  /// closing the last tab on this book: tears down all of its terminal
  /// tabs, which lets the existing `tabClosed(remainingTabs: 0)` →
  /// `markWorktreeClosed` pipeline retire the book from the Shelf and
  /// auto-advance selection. Intentionally does *not* archive the
  /// worktree or remove the repository — Shelf removal is a view-state
  /// concern, not a destructive resource operation.
  private func closeBook(_ book: ShelfBook) {
    if let state = terminalManager.stateIfExists(for: book.id), !state.tabManager.tabs.isEmpty {
      state.closeAllTabs()
    } else {
      // No live tabs to fall through the closeAllTabs → tabClosed
      // pipeline — drive the Shelf removal directly.
      store.send(.markWorktreeClosed(book.id))
    }
  }

  private func closeMenuTitle(for book: ShelfBook) -> String {
    switch book.kind {
    case .worktree: String(localized: "Close Worktree")
    case .plainFolder: String(localized: "Close Folder")
    }
  }

  private func isOpen(_ book: ShelfBook) -> Bool {
    store.state.openShelfBookID == book.id
  }

  @ViewBuilder
  private func openBookArea(for book: ShelfBook, state: RepositoriesFeature.State) -> some View {
    if let worktree = state.selectedTerminalWorktree, worktree.id == book.id {
      let shouldFocus = state.shouldFocusTerminal(for: worktree.id)
      ShelfOpenBookView(
        worktree: worktree,
        manager: terminalManager,
        shouldRunSetupScript: state.pendingSetupScriptWorktreeIDs.contains(worktree.id),
        forceAutoFocus: shouldFocus
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .id(worktree.id)
      .onAppear {
        if shouldFocus {
          store.send(.worktreeCreation(.consumeTerminalFocus(worktree.id)))
        }
      }
    } else {
      emptyOpenArea()
    }
  }

  @ViewBuilder
  private func emptyOpenArea() -> some View {
    ContentUnavailableView(
      "No worktree selected",
      systemImage: "books.vertical",
      description: Text("Click a worktree to open it.")
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Open `book` and optionally select a specific tab on it. For the open
  /// book's own tab slots (no book change), this skips the worktree
  /// re-selection and just tells the tab manager to switch tab.
  private func openBook(_ book: ShelfBook, selectingTab tabID: TerminalTabID?) {
    let isAlreadyOpen = store.state.openShelfBookID == book.id
    if let tabID, isAlreadyOpen, let state = terminalManager.stateIfExists(for: book.id) {
      shelfLogger.event("BookClick.TabSwitchSameBook")
      state.tabManager.selectTab(tabID)
      return
    }
    shelfLogger.event("BookClick.SwitchBook")
    // The spine flow / terminal crossfade animation is already driven
    // by the view-level `.animation(_:value: openBookID)` on the root
    // container (~200ms ease-in-out per the Shelf design doc), so the
    // dispatch itself does not pass an `animation:` argument here.
    switch book.kind {
    case .worktree:
      store.send(.selectWorktree(book.id, focusTerminal: true))
    case .plainFolder:
      store.send(.selectRepository(book.repositoryID))
    }
    if let tabID {
      // Apply tab selection eagerly; the target book's state already exists
      // if the user has opened it before. For first-time opens the tab
      // manager seeds a default tab which we won't override.
      terminalManager.stateIfExists(for: book.id)?.tabManager.selectTab(tabID)
    }
  }
}

enum ShelfSwipeNavigationAction: Equatable {
  case nextBook
  case previousBook
  case nextTab
  case previousTab
}

struct ShelfSwipeGestureClassifier {
  static let swipeThreshold: CGFloat = 80
  static let axisDominanceRatio: CGFloat = 1.6

  static func action(
    accumulatedDeltaX: CGFloat,
    accumulatedDeltaY: CGFloat
  ) -> ShelfSwipeNavigationAction? {
    let absX = abs(accumulatedDeltaX)
    let absY = abs(accumulatedDeltaY)
    if absX >= swipeThreshold, absX > absY * axisDominanceRatio {
      return accumulatedDeltaX > 0 ? .previousBook : .nextBook
    }
    if absY >= swipeThreshold, absY > absX * axisDominanceRatio {
      return accumulatedDeltaY > 0 ? .previousTab : .nextTab
    }
    return nil
  }
}

private struct ShelfSwipeEventMonitor: NSViewRepresentable {
  let isEnabled: Bool
  let onSwipe: (ShelfSwipeNavigationAction) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.view = view
    context.coordinator.installIfNeeded()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.view = nsView
    context.coordinator.isEnabled = isEnabled
    context.coordinator.onSwipe = onSwipe
    context.coordinator.installIfNeeded()
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.removeMonitor()
  }

  final class Coordinator {
    weak var view: NSView?
    var isEnabled = false
    var onSwipe: (ShelfSwipeNavigationAction) -> Void = { _ in }

    private var monitor: Any?
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0
    private var lastEventTimestamp: TimeInterval = 0
    private var didTriggerCurrentGesture = false

    private let eventGapResetInterval: TimeInterval = 0.25

    func installIfNeeded() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        self?.handle(event) ?? event
      }
    }

    func removeMonitor() {
      guard let monitor else { return }
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
      guard isEnabled,
        let view,
        let window = view.window,
        event.window === window,
        view.bounds.contains(view.convert(event.locationInWindow, from: nil))
      else {
        resetGesture()
        return event
      }

      guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else {
        resetGesture()
        return event
      }

      if event.phase.contains(.began)
        || event.timestamp - lastEventTimestamp > eventGapResetInterval
      {
        resetGesture()
      }
      lastEventTimestamp = event.timestamp

      if didTriggerCurrentGesture {
        if event.phase.contains(.ended) || event.phase.contains(.cancelled)
          || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
        {
          resetGesture()
        }
        return nil
      }

      guard event.momentumPhase.isEmpty else {
        return nil
      }

      accumulatedDeltaX += event.scrollingDeltaX
      accumulatedDeltaY += event.scrollingDeltaY

      guard
        let action = ShelfSwipeGestureClassifier.action(
          accumulatedDeltaX: accumulatedDeltaX,
          accumulatedDeltaY: accumulatedDeltaY
        )
      else {
        return nil
      }

      resetAccumulatedDeltas()
      didTriggerCurrentGesture = true
      onSwipe(action)
      return nil
    }

    private func resetGesture() {
      resetAccumulatedDeltas()
      didTriggerCurrentGesture = false
    }

    private func resetAccumulatedDeltas() {
      accumulatedDeltaX = 0
      accumulatedDeltaY = 0
    }
  }
}
