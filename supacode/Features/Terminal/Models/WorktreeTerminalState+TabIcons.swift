import Foundation
import ProwlCLIShared

extension WorktreeTerminalState {
  // MARK: - Tab Icon Auto-Detection
  //
  // Strategy: each OSC 2 title change is matched against
  // `CommandIconMap` (substring rules first, then first-token). A hit
  // applies the icon immediately - no debounce. Rationale: the
  // mapping is a curated allow-list, so a hit is by definition a
  // command we're happy to brand the tab with; a miss leaves the
  // existing icon untouched (selection-2 semantics).
  //
  // Idle-prompt suppression keeps the lookup focused on real
  // commands: the first title after each `command_finished` is the
  // shell's `precmd`-set prompt, and gets memorised into a learned-
  // idle set so we never reach the mapping with a `user@host`-style
  // string. Shape heuristics (`isLikelyIdleTitleByShape`) cover the
  // bootstrap window before the learner has seen anything.
  //
  // The mapping-hit-equals-apply rule also unblocks short-lived
  // commands (`git status`, `cd foo`) and TUIs that immediately
  // overwrite their preexec title (`codex` -> repo name) - both used
  // to slip past a debounce-based detector.

  func noteTitleForCommandDetection(_ rawTitle: String, surfaceId: UUID, tabId: TerminalTabID) {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    // Learn this surface's idle prompt: the first title after
    // `command_finished` is reliably the precmd-set one.
    if awaitingIdleTitleLearningBySurface.remove(surfaceId) != nil {
      learnedIdleTitlesBySurface[surfaceId, default: []].insert(title)
    }
    // Drop idle prompts so they can't reach the mapping lookup.
    if Self.isLikelyIdleTitleByShape(title) { return }
    if learnedIdleTitlesBySurface[surfaceId]?.contains(title) == true { return }
    guard let icon = CommandIconMap.iconForFirstToken(title) else { return }
    applyResolvedIcon(icon, surfaceId: surfaceId, tabId: tabId)
  }

  func noteCommandFinishedForCommandDetection(surfaceId: UUID) {
    // Arm the idle-prompt learner: the next title arrival is the
    // precmd-set prompt and should join the learned-idle set.
    awaitingIdleTitleLearningBySurface.insert(surfaceId)
  }

  /// Drop the per-surface detector state. Called when a surface is
  /// closed or its parent tab is torn down so we don't retain
  /// learned-idle sets keyed by ids that will never emit again.
  func cleanupCommandDetectorState(forSurfaceId surfaceId: UUID) {
    learnedIdleTitlesBySurface.removeValue(forKey: surfaceId)
    awaitingIdleTitleLearningBySurface.remove(surfaceId)
  }

  /// Heuristic shape-only detection for shell idle prompts. The
  /// bootstrap filter - before `awaitingIdleTitleLearning` has caught
  /// the precmd-set prompt at least once on this surface - for two
  /// common forms:
  ///   1. `user@host[:path]` - contains `@` plus `:` or `/`, no spaces.
  ///   2. Pure path - starts with `~`, `/`, or `…`, no spaces.
  /// Real commands typically contain a space (program + args) or a
  /// short single token (`ls`, `claude`, `vim`) that doesn't match
  /// either shape, so the false-negative risk is small.
  ///
  /// Exposed (`internal static`) for direct unit testing - does not
  /// touch instance state.
  static func isLikelyIdleTitleByShape(_ title: String) -> Bool {
    guard !title.contains(" ") else { return false }
    if title.contains("@"), title.contains(":") || title.contains("/") {
      return true
    }
    if title.hasPrefix("~") || title.hasPrefix("/") || title.hasPrefix("…") {
      return true
    }
    return false
  }

  /// Apply an already-resolved icon to the tab. Honours focus, the user
  /// icon lock, and the Run Script / Custom Command override; encodes
  /// the icon through `storageString` so `assetName`-bearing entries
  /// pick up the `@asset:` marker the renderers parse via
  /// `ResolvedTabIcon`.
  func applyResolvedIcon(
    _ icon: TabIconSource,
    surfaceId: UUID,
    tabId: TerminalTabID
  ) {
    // Per-tab UI is single-headed: only the focused surface in a
    // multi-split tab gets to drive its tab's icon. Stops a
    // background split's command from silently overriding what the
    // user is currently looking at.
    guard focusedSurfaceIdByTab[tabId] == surfaceId else { return }
    guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
    guard tab.iconLock == .auto else { return }
    let serialised = icon.storageString
    guard tab.icon != serialised else { return }
    tabManager.updateIcon(tabId, icon: serialised)
  }
}
