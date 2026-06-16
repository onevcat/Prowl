import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct ActiveAgentsFeatureTests {
  @Test func entriesKeepInsertionOrder() async {
    let store = TestStore(initialState: ActiveAgentsFeature.State()) {
      ActiveAgentsFeature()
    }

    let old = Date(timeIntervalSince1970: 10)
    let new = Date(timeIntervalSince1970: 20)
    let idle = entry(id: UUID(0), state: .idle, changedAt: new)
    let blocked = entry(id: UUID(1), state: .blocked, changedAt: old)
    let working = entry(id: UUID(2), state: .working, changedAt: new)
    let done = entry(id: UUID(3), state: .done, changedAt: new)
    let updatedIdle = entry(id: UUID(0), state: .blocked, changedAt: Date(timeIntervalSince1970: 30))

    await store.send(.agentEntryChanged(idle, autoShowPanel: false)) {
      $0.entries = [idle]
    }
    await store.send(.agentEntryChanged(blocked, autoShowPanel: false)) {
      $0.entries = [idle, blocked]
    }
    await store.send(.agentEntryChanged(working, autoShowPanel: false)) {
      $0.entries = [idle, blocked, working]
    }
    await store.send(.agentEntryChanged(done, autoShowPanel: false)) {
      $0.entries = [idle, blocked, working, done]
    }
    await store.send(.agentEntryChanged(updatedIdle, autoShowPanel: false)) {
      $0.entries = [updatedIdle, blocked, working, done]
    }
  }

  @Test func autoShowRevealsHiddenPanelOnAgentEntry() async {
    let state = ActiveAgentsFeature.State()
    state.$isPanelHidden.withLock { $0 = true }
    let store = TestStore(initialState: state) {
      ActiveAgentsFeature()
    }
    let agent = entry(id: UUID(0), state: .working, changedAt: Date(timeIntervalSince1970: 10))

    await store.send(.agentEntryChanged(agent, autoShowPanel: true)) {
      $0.entries = [agent]
      $0.$isPanelHidden.withLock { $0 = false }
    }
  }

  @Test func panelHeightIsClamped() async {
    let store = TestStore(initialState: ActiveAgentsFeature.State()) {
      ActiveAgentsFeature()
    }

    await store.send(.panelHeightChanged(20)) {
      $0.$panelHeight.withLock { $0 = 120 }
    }
    await store.send(.panelHeightChanged(900)) {
      $0.$panelHeight.withLock { $0 = 560 }
    }
  }

  @Test func maximumPanelHeightKeepsRepositoryListVisible() {
    #expect(ActiveAgentsFeature.maximumPanelHeight(forContainerHeight: 900) == 560)
    #expect(ActiveAgentsFeature.maximumPanelHeight(forContainerHeight: 500) == 300)
    #expect(ActiveAgentsFeature.maximumPanelHeight(forContainerHeight: 250) == 120)
  }

  @Test func rowDisplayUsesDetectedCommandTokenBeforeAgentFallback() {
    let ompEntry = entry(
      id: UUID(0),
      state: .idle,
      changedAt: Date(timeIntervalSince1970: 10),
      agent: .pi,
      iconLookupToken: "omp"
    )
    #expect(ompEntry.iconSource?.assetName == "OMP")
    #expect(ompEntry.displayName == "omp")

    let fallbackEntry = entry(
      id: UUID(1),
      state: .idle,
      changedAt: Date(timeIntervalSince1970: 10),
      agent: .pi,
      iconLookupToken: "unknown-wrapper"
    )
    #expect(fallbackEntry.iconSource?.assetName == "Pi")
    #expect(fallbackEntry.displayName == "pi")

    let cursorEntry = entry(
      id: UUID(2),
      state: .idle,
      changedAt: Date(timeIntervalSince1970: 10),
      agent: .cursor,
      iconLookupToken: "agent"
    )
    #expect(cursorEntry.displayName == "cursor")
  }

  @Test func navigationReturnsNilForEmptyList() {
    let entries: IdentifiedArrayOf<ActiveAgentEntry> = []
    #expect(ActiveAgentsFeature.entryID(navigatingFrom: nil, direction: .next, in: entries) == nil)
    #expect(ActiveAgentsFeature.entryID(navigatingFrom: nil, direction: .previous, in: entries) == nil)
  }

  @Test func navigationWithoutAnchorStartsFromEdges() {
    let entries = sampleEntries()
    // No focus, or focus on a surface that is not in the list, anchors on an edge.
    #expect(ActiveAgentsFeature.entryID(navigatingFrom: nil, direction: .next, in: entries) == UUID(0))
    #expect(ActiveAgentsFeature.entryID(navigatingFrom: nil, direction: .previous, in: entries) == UUID(2))
    #expect(ActiveAgentsFeature.entryID(navigatingFrom: UUID(99), direction: .next, in: entries) == UUID(0))
    #expect(ActiveAgentsFeature.entryID(navigatingFrom: UUID(99), direction: .previous, in: entries) == UUID(2))
  }

  @Test func navigationStepsAndWrapsAroundAnchor() {
    let entries = sampleEntries()
    #expect(ActiveAgentsFeature.entryID(navigatingFrom: UUID(0), direction: .next, in: entries) == UUID(1))
    #expect(ActiveAgentsFeature.entryID(navigatingFrom: UUID(2), direction: .next, in: entries) == UUID(0))
    #expect(ActiveAgentsFeature.entryID(navigatingFrom: UUID(1), direction: .previous, in: entries) == UUID(0))
    #expect(ActiveAgentsFeature.entryID(navigatingFrom: UUID(0), direction: .previous, in: entries) == UUID(2))
  }

  @Test func selectNextEntryAdvancesAnchorAndTapsNeighbour() async {
    var state = ActiveAgentsFeature.State()
    state.entries = sampleEntries()
    state.focusedSurfaceID = UUID(0)
    let store = TestStore(initialState: state) {
      ActiveAgentsFeature()
    }

    await store.send(.selectNextEntry) {
      $0.focusedSurfaceID = UUID(1)
    }
    await store.receive(.entryTapped(UUID(1)))
  }

  @Test func selectPreviousEntryWrapsToLastWhenAtFirst() async {
    var state = ActiveAgentsFeature.State()
    state.entries = sampleEntries()
    state.focusedSurfaceID = UUID(0)
    let store = TestStore(initialState: state) {
      ActiveAgentsFeature()
    }

    await store.send(.selectPreviousEntry) {
      $0.focusedSurfaceID = UUID(2)
    }
    await store.receive(.entryTapped(UUID(2)))
  }

  @Test func navigationWithoutEntriesIsNoOp() async {
    let store = TestStore(initialState: ActiveAgentsFeature.State()) {
      ActiveAgentsFeature()
    }

    await store.send(.selectNextEntry)
    await store.send(.selectPreviousEntry)
  }

  @Test func entryTappedUpdatesFocusAnchor() async {
    var state = ActiveAgentsFeature.State()
    state.entries = sampleEntries()
    let store = TestStore(initialState: state) {
      ActiveAgentsFeature()
    }

    // Tapping mirrors the entry's surface into the focus anchor so keyboard
    // navigation continues from the just-selected agent, without relying on the
    // (per-worktree deduplicated) async `focusChanged` event.
    await store.send(.entryTapped(UUID(2))) {
      $0.focusedSurfaceID = UUID(2)
    }
  }

  @Test func focusedSurfaceChangedUpdatesAnchor() async {
    let store = TestStore(initialState: ActiveAgentsFeature.State()) {
      ActiveAgentsFeature()
    }

    await store.send(.focusedSurfaceChanged(UUID(7))) {
      $0.focusedSurfaceID = UUID(7)
    }
    await store.send(.focusedSurfaceChanged(nil)) {
      $0.focusedSurfaceID = nil
    }
  }

  @Test func panelSubtitleSwapsTabTitleAndBranchWhenEnabled() {
    let entry = entry(id: UUID(0), tabTitle: "Review issue 385", state: .idle, changedAt: Date())

    #expect(
      ActiveAgentsPanel.subtitle(for: entry, branchName: "main", showTabTitles: false)
        == "main"
    )
    #expect(
      ActiveAgentsPanel.subtitle(for: entry, branchName: "main", showTabTitles: true)
        == "Review issue 385"
    )
  }

  @Test func panelHelpTextUsesFullPrimaryTitle() {
    let titledEntry = entry(
      id: UUID(0),
      tabTitle: "Review issue 385",
      conversationTitle: "定位 active agents 标题检测",
      state: .idle,
      changedAt: Date()
    )
    let fallbackEntry = entry(id: UUID(1), tabTitle: "Review issue 385", state: .idle, changedAt: Date())

    #expect(
      ActiveAgentsPanel.helpText(for: titledEntry, repositoryName: "Prowl")
        == "定位 active agents 标题检测"
    )
    #expect(
      ActiveAgentsPanel.helpText(for: fallbackEntry, repositoryName: "Prowl")
        == "codex · Prowl"
    )
  }

  @Test func panelTabTitleFallsBackForEmptyTitles() {
    let entry = entry(id: UUID(0), tabTitle: "   ", state: .idle, changedAt: Date())

    #expect(ActiveAgentsPanel.tabTitle(for: entry) == "Untitled tab")
  }

  @Test func codexConversationTitleReadsFirstUserMessageFromMatchingSession() throws {
    let sessionsRoot = FileManager.default.temporaryDirectory
      .appending(path: "prowl-codex-title-\(UUID().uuidString)", directoryHint: .isDirectory)
    let sessionDirectory = sessionsRoot
      .appending(path: "2026/06/16", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let sessionFile = sessionDirectory.appending(path: "rollout-test.jsonl")
    try """
      {"type":"session_meta","payload":{"id":"test","cwd":"/Users/yam/Developer/Prowl","source":"cli","originator":"codex-tui"}}
      {"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"ignored"}]}}
      {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<user_message>\\n现在 active 还有点弱，我想实现一个像 codex app 这样的功能，\\n有一个明确的标题和状态\\n</user_message>"}]}}
      """.write(to: sessionFile, atomically: true, encoding: .utf8)

    let title = ActiveAgentConversationTitle.title(
      for: .codex,
      workingDirectory: URL(filePath: "/Users/yam/Developer/Prowl"),
      sessionsRoot: sessionsRoot,
      now: Date()
    )

    #expect(title == "现在 active 还有点弱，我想实现一个像 codex app 这样的功能，有一个明确的标题和状态")
  }

  @Test func codexConversationTitleSkipsInjectedContextAndReadsMarkedRequest() throws {
    let sessionsRoot = FileManager.default.temporaryDirectory
      .appending(path: "prowl-codex-title-\(UUID().uuidString)", directoryHint: .isDirectory)
    let sessionDirectory = sessionsRoot
      .appending(path: "2026/06/16", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let sessionFile = sessionDirectory.appending(path: "rollout-test.jsonl")
    try """
      {"type":"session_meta","payload":{"id":"test","cwd":"/Users/yam/Developer/Prowl","source":"cli","originator":"codex-tui"}}
      {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /Users/yam/Developer/Prowl\\n\\n<INSTRUCTIONS>\\nUse local rules.\\n</INSTRUCTIONS>"},{"type":"input_text","text":"<environment_context>\\n  <cwd>/Users/yam/Developer/Prowl</cwd>\\n</environment_context>"},{"type":"input_text","text":"# Files mentioned by the user:\\n\\n## CleanShot.png\\n\\n## My request for Codex:\\n有两个问题 1 你好像取的是完整的 prompt 而不是我输入的文字？ 2 hover 上为什么是分支名？"}]}}
      """.write(to: sessionFile, atomically: true, encoding: .utf8)

    let title = ActiveAgentConversationTitle.title(
      for: .codex,
      workingDirectory: URL(filePath: "/Users/yam/Developer/Prowl"),
      sessionsRoot: sessionsRoot,
      now: Date()
    )

    #expect(title == "有两个问题 1 你好像取的是完整的 prompt 而不是我输入的文字？ 2 hover 上为什么是分支名？")
  }

  @Test func codexConversationTitleIgnoresUnmatchedSessionDirectories() throws {
    let sessionsRoot = FileManager.default.temporaryDirectory
      .appending(path: "prowl-codex-title-\(UUID().uuidString)", directoryHint: .isDirectory)
    let sessionDirectory = sessionsRoot
      .appending(path: "2026/06/16", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    let sessionFile = sessionDirectory.appending(path: "rollout-test.jsonl")
    try """
      {"type":"session_meta","payload":{"id":"test","cwd":"/Users/yam/Developer/Other","source":"cli","originator":"codex-tui"}}
      {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"不要展示这个"}]}}
      """.write(to: sessionFile, atomically: true, encoding: .utf8)

    let title = ActiveAgentConversationTitle.title(
      for: .codex,
      workingDirectory: URL(filePath: "/Users/yam/Developer/Prowl"),
      sessionsRoot: sessionsRoot,
      now: Date()
    )

    #expect(title == nil)
  }

  @Test func rowTitlePrefersConversationTitleOverAgentRepositoryLabel() {
    let entry = entry(
      id: UUID(0),
      conversationTitle: "查明 Cmd+Opt+P 绑定",
      state: .working,
      changedAt: Date()
    )

    #expect(ActiveAgentRow.primaryTitle(for: entry, repositoryName: "Prowl") == "查明 Cmd+Opt+P 绑定")
  }

  @Test func rowTitleFallsBackToAgentRepositoryLabel() {
    let entry = entry(id: UUID(0), state: .working, changedAt: Date())

    #expect(ActiveAgentRow.primaryTitle(for: entry, repositoryName: "Prowl") == "codex · Prowl")
  }

  @Test func agentIconTintUsesBrandIdentityColors() {
    #expect(AgentIconTint.colorHex(for: .claude) == "#D97757")
    #expect(AgentIconTint.colorHex(for: .codex) == "#6370F2")
    #expect(AgentIconTint.colorHex(for: .gemini) == "#8E75B2")
  }

  private func sampleEntries() -> IdentifiedArrayOf<ActiveAgentEntry> {
    let now = Date(timeIntervalSince1970: 10)
    return [
      entry(id: UUID(0), state: .working, changedAt: now),
      entry(id: UUID(1), state: .idle, changedAt: now),
      entry(id: UUID(2), state: .blocked, changedAt: now),
    ]
  }

  private func entry(
    id: UUID,
    tabTitle: String = "1",
    conversationTitle: String? = nil,
    state: AgentDisplayState,
    changedAt: Date,
    agent: DetectedAgent = .codex,
    iconLookupToken: String? = nil
  ) -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: id,
      worktreeID: "/repo/wt",
      worktreeName: "wt",
      workingDirectory: nil,
      tabID: TerminalTabID(rawValue: UUID()),
      tabTitle: tabTitle,
      conversationTitle: conversationTitle,
      surfaceID: id,
      paneIndex: 1,
      iconLookupToken: iconLookupToken ?? agent.iconLookupToken,
      agent: agent,
      rawState: state == .blocked ? .blocked : state == .working ? .working : .idle,
      displayState: state,
      lastChangedAt: changedAt
    )
  }
}

extension UUID {
  fileprivate init(_ value: UInt8) {
    self.init(uuid: (value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  }
}
