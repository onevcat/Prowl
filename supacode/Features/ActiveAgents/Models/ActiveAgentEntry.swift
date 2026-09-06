import Foundation
import ProwlCLIShared

struct ActiveAgentEntry: Identifiable, Equatable, Sendable {
  let id: UUID
  /// The worktree that physically owns the agent's terminal surface (the tab's worktree).
  /// Drives navigation/focus (`focusSurface`/`selectWorktree`), so it must stay the surface's
  /// real owner even when the agent runs in a different directory. Display name/branch come from
  /// `workingDirectory` instead — see `SidebarListView.activeAgentRowDisplay`.
  let worktreeID: Worktree.ID
  let worktreeName: String
  /// The agent's current working directory at detection time, used to resolve the displayed
  /// repository/branch. `nil` when the terminal hasn't reported a directory, in which case the
  /// display falls back to `worktreeID`/`worktreeName`.
  let workingDirectory: URL?
  let tabID: TerminalTabID
  /// The title of the agent's own pane: the surface's live title when it has one,
  /// falling back to the tab's display title. Kept per-pane so agents in different
  /// splits of one tab don't all mirror the focused pane's title.
  /// A `var` so `equalsIgnoringRawStateAndPaneTitle` can normalize it.
  var paneTitle: String
  let surfaceID: UUID
  let paneIndex: Int
  /// Command/process token used for row icon lookup. This can be more specific than
  /// `agent` for aliases or wrappers, e.g. `oh-my-pi` vs `omp`.
  let iconLookupToken: String
  let agent: DetectedAgent
  var session: AgentSession?
  /// Un-stabilized per-poll detection result. Surfaced only by `prowl agents`
  /// (`raw_state`); no SwiftUI view renders it (they show `displayState`). A
  /// `var` so `equalsIgnoringRawState` can normalize it for emission dedup.
  var rawState: AgentRawState
  let displayState: AgentDisplayState
  let lastChangedAt: Date
  /// Profile display name recorded at launch for Prowl-launched surfaces
  /// (docs-ai 053). Detected-but-not-launched agents stay honest: nil, so
  /// the row never guesses a profile attribution.
  var launchProfileName: String?
  var displayName: String {
    launchProfileName ?? Self.displayName(iconLookupToken: iconLookupToken, agent: agent)
  }

  /// Equality for emission purposes, excluding `rawState`. `rawState` oscillates
  /// on every 300 ms poll while an agent animates its spinner; if it gated
  /// emission, each flicker would push a new entry into `ActiveAgentsFeature`
  /// state and re-render the whole sidebar for a value no view displays.
  /// `rawState` still rides along on entries that emit for a visible reason, so
  /// `prowl agents` reports the raw state as of the last visible change.
  func equalsIgnoringRawState(_ other: ActiveAgentEntry) -> Bool {
    var normalized = self
    normalized.rawState = other.rawState
    return normalized == other
  }

  /// Equality ignoring `rawState` and `paneTitle`. Agent TUIs animate a spinner
  /// glyph inside the terminal title (`⠦ spx-h` → `⠧ spx-h`), so the title
  /// changes several times a second while nothing a user would call a change has
  /// happened. Callers use this to recognize a title-only difference and space
  /// those emissions out instead of forwarding every animation frame.
  func equalsIgnoringRawStateAndPaneTitle(_ other: ActiveAgentEntry) -> Bool {
    var normalized = self
    normalized.rawState = other.rawState
    normalized.paneTitle = other.paneTitle
    return normalized == other
  }

  /// The user-facing agent name: the launch command token (e.g. `omp`) when it
  /// maps to a known icon, else the semantic agent name. Shared by
  /// the panel rows and the toolbar Agents capsule so both always agree.
  static func displayName(iconLookupToken: String, agent: DetectedAgent) -> String {
    let trimmed = iconLookupToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !trimmed.isEmpty,
      trimmed != "agent",
      CommandIconMap.iconForFirstToken(trimmed) != nil
    else {
      return agent.displayName
    }
    return trimmed
  }

  var iconSource: TabIconSource? {
    CommandIconMap.iconForFirstToken(iconLookupToken) ?? CommandIconMap.iconForFirstToken(agent.iconLookupToken)
  }
}
