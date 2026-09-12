import Foundation
import Testing

@testable import supacode

struct HerdrTabBarViewTests {
  @Test func activeStructuredTitlesRestorePrimaryEmphasis() {
    #expect(HerdrTabBarProjection.contextTone(isActive: true) == .primary)
    #expect(HerdrTabBarProjection.contextTone(isActive: false) == .secondary)
    #expect(HerdrTabBarProjection.linkedRepoTone(isActive: true) == .primary)
    #expect(HerdrTabBarProjection.linkedRepoTone(isActive: false) == .secondary)
    #expect(HerdrTabBarProjection.linkedCheckoutTone(isActive: true) == .secondary)
    #expect(HerdrTabBarProjection.linkedCheckoutTone(isActive: false) == .tertiary)
  }

  @Test func linkedWorktreeTitleUsesTheRequestedSizeHierarchy() {
    #expect(HerdrChromeTypography.processTitleFontSize == 14.5)
    #expect(HerdrChromeTypography.linkedWorktreeRepoFontSize == 15)
    #expect(HerdrChromeTypography.tabTitleFontSize == 14.5)
  }

  @Test func projectsOnlyFocusedWorkspaceTabsAndZoomSuffix() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t2",
      focusedPaneID: nil,
      workspaces: [],
      tabs: [
        HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "shell"),
        HerdrTab(tabID: "w2:t1", workspaceID: "w2", label: "other"),
        HerdrTab(tabID: "w1:t2", workspaceID: "w1", label: "logs", focused: true),
      ],
      panes: [],
      layouts: [HerdrLayout(workspaceID: "w1", tabID: "w1:t2", zoomed: true)],
      agents: []
    )

    let items = HerdrTabBarProjection.items(in: snapshot, workspaceID: "w1")

    #expect(items.map(\.id) == ["w1:t1", "w1:t2"])
    #expect(items.map(\.displayLabel) == ["shell", "logs Z"])
    #expect(items.last?.isFocused == true)
    #expect(items.allSatisfy { !$0.isAgent })
  }

  @Test func marksTabsContainingAgentsForLeadingIcon() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "w1:p1",
      workspaces: [],
      tabs: [
        HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "agent"),
        HerdrTab(tabID: "w1:t2", workspaceID: "w1", label: "shell"),
      ],
      panes: [],
      layouts: [],
      agents: [HerdrAgent(paneID: "w1:p1", tabID: "w1:t1", agent: "codex")]
    )

    let items = HerdrTabBarProjection.items(in: snapshot, workspaceID: "w1")

    #expect(items.first?.isAgent == true)
    #expect(items.first?.agentKind == .codex)
    #expect(items.last?.isAgent == false)
  }

  @Test func mapsProviderIDsToCanonicalTabIcons() {
    let providerIDs = [
      "codex", "claude-code", "pi", "acp-cursor", "acp-opencode", "acp-omp", "acp-grok", "fx",
    ]
    let tabs = providerIDs.map { HerdrTab(tabID: "w1:\($0)", workspaceID: "w1", label: $0) }
    let agents = providerIDs.map {
      HerdrAgent(paneID: "p:\($0)", tabID: "w1:\($0)", agent: $0)
    }
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: nil,
      focusedPaneID: nil,
      workspaces: [],
      tabs: tabs,
      panes: [],
      layouts: [],
      agents: agents
    )

    let kinds = HerdrTabBarProjection.items(in: snapshot, workspaceID: "w1").compactMap(\.agentKind)

    #expect(kinds == [.codex, .claude, .pi, .cursor, .opencode, .omp, .grok, .fx])
    #expect(HerdrTabAgentKind.resolve(HerdrAgent(agent: "acp-other")) == .generic)
  }

  @Test func prefersFocusedKnownProviderWhenATabHasMultipleAgents() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "p2",
      workspaces: [],
      tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "mixed")],
      panes: [],
      layouts: [],
      agents: [
        HerdrAgent(paneID: "p1", tabID: "w1:t1", agent: "acp-unknown"),
        HerdrAgent(paneID: "p2", tabID: "w1:t1", agent: "acp-omp", focused: true),
      ]
    )

    let item = HerdrTabBarProjection.items(in: snapshot, workspaceID: "w1").first

    #expect(item?.agentKind == .omp)
  }

  @Test func projectsMeaningfulForegroundProcessWithDirectory() {
    let processInfo = HerdrPaneProcessInfo(
      paneID: "w1:p1",
      shellPID: 10,
      foregroundProcessGroupID: 20,
      foregroundProcesses: [
        HerdrPaneProcess(pid: 10, name: "zsh", argv0: "/bin/zsh"),
        HerdrPaneProcess(
          pid: 20,
          name: "lazygit",
          argv0: "lazygit",
          cwd: "/Users/yam/Developer/Prowl"
        ),
        HerdrPaneProcess(pid: 21, name: "starship", argv0: "starship"),
      ]
    )

    #expect(
      HerdrTabBarProjection.processTitle(
        in: processInfo,
        fallbackDirectory: "/Users/yam/Developer/Prowl"
      ) == HerdrProcessTitle(processName: "lazygit", directoryName: "Prowl")
    )
  }

  @Test func mapsRemoteShellForegroundProcessesToTheSshIcon() {
    #expect(HerdrProcessIcon(processName: "ssh") == .ssh)
    #expect(HerdrProcessIcon(processName: "SSH") == .ssh)
    #expect(HerdrProcessIcon(processName: "mosh-client") == .ssh)
    #expect(HerdrProcessIcon(processName: "zsh") == nil)
    #expect(HerdrProcessIcon(processName: "lazygit") == nil)
    #expect(HerdrProcessTitle(processName: "ssh", directoryName: "prod").icon == .ssh)
    #expect(HerdrProcessTitle(processName: "ssh", directoryName: "prod").rendersIconOnly)
    #expect(!HerdrProcessTitle(processName: "zsh", directoryName: "Prowl").rendersIconOnly)
    #expect(HerdrProcessTitle(processName: "zsh", directoryName: "Prowl").icon == nil)
  }

  @Test func brandsSshForegroundTabsWithTheSshIcon() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "w1:p1",
      workspaces: [],
      tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "remote")],
      panes: [
        HerdrPane(
          paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", focused: true, cwd: "/tmp/prod")
      ],
      layouts: [],
      agents: []
    )
    let processInfoByPaneID = [
      "w1:p1": HerdrPaneProcessInfo(
        paneID: "w1:p1",
        shellPID: 10,
        foregroundProcessGroupID: 20,
        foregroundProcesses: [
          HerdrPaneProcess(pid: 10, name: "zsh", argv0: "/bin/zsh"),
          HerdrPaneProcess(pid: 20, name: "ssh", argv0: "ssh", cwd: "/tmp/prod"),
        ]
      )
    ]

    let item = HerdrTabBarProjection.items(
      in: snapshot,
      workspaceID: "w1",
      processInfoByPaneID: processInfoByPaneID,
      focusedPaneID: "w1:p1"
    ).first

    #expect(item?.processTitle == HerdrProcessTitle(processName: "ssh", directoryName: "prod"))
    #expect(item?.processIcon == .ssh)
    #expect(item?.agentKind == nil)
  }

  @Test func agentKindKeepsPrecedenceOverTheSshProcessIcon() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "w1:p1",
      workspaces: [],
      tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "agent")],
      panes: [
        HerdrPane(
          paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", focused: true, cwd: "/tmp/prod")
      ],
      layouts: [],
      agents: [HerdrAgent(paneID: "w1:p1", tabID: "w1:t1", agent: "codex")]
    )
    let processInfoByPaneID = [
      "w1:p1": HerdrPaneProcessInfo(
        paneID: "w1:p1",
        shellPID: 10,
        foregroundProcessGroupID: 20,
        foregroundProcesses: [
          HerdrPaneProcess(pid: 10, name: "zsh", argv0: "/bin/zsh"),
          HerdrPaneProcess(pid: 20, name: "ssh", argv0: "ssh", cwd: "/tmp/prod"),
        ]
      )
    ]

    let item = HerdrTabBarProjection.items(
      in: snapshot,
      workspaceID: "w1",
      processInfoByPaneID: processInfoByPaneID,
      focusedPaneID: "w1:p1"
    ).first

    #expect(item?.agentKind == .codex)
    #expect(item?.processIcon == .ssh)
  }

  @Test func decodesLinkedWorktreeProvenance() throws {
    let workspace = try JSONDecoder().decode(
      HerdrWorkspace.self,
      from: Data(
        #"""
        {
          "workspace_id": "w1",
          "label": "feature",
          "worktree": {
            "repo_key": "/Users/yam/Developer/Warlock",
            "repo_name": "Warlock",
            "repo_root": "/Users/yam/Developer/Warlock",
            "checkout_path": "/Users/yam/Developer/warlock-ios-simulator-replay",
            "is_linked_worktree": true
          }
        }
        """#.utf8
      )
    )

    #expect(workspace.worktree?.repoName == "Warlock")
    #expect(workspace.worktree?.checkoutPath == "/Users/yam/Developer/warlock-ios-simulator-replay")
    #expect(workspace.worktree?.isLinkedWorktree == true)
  }

  @Test func linkedWorktreeProcessTitleKeepsMainRepositoryAndCheckoutIdentity() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "w1:p1",
      workspaces: [
        HerdrWorkspace(
          workspaceID: "w1",
          worktree: HerdrWorkspaceWorktree(
            repoName: "Warlock",
            repoRoot: "/Users/yam/Developer/Warlock",
            checkoutPath: "/Users/yam/Developer/warlock-ios-simulator-replay",
            isLinkedWorktree: true
          )
        )
      ],
      tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "feature")],
      panes: [
        HerdrPane(
          paneID: "w1:p1",
          workspaceID: "w1",
          tabID: "w1:t1",
          focused: true,
          cwd: "/Users/yam/Developer/warlock-ios-simulator-replay"
        )
      ],
      layouts: [],
      agents: []
    )
    let processInfo = HerdrPaneProcessInfo(
      paneID: "w1:p1",
      shellPID: 10,
      foregroundProcessGroupID: 20,
      foregroundProcesses: [HerdrPaneProcess(pid: 20, name: "lazygit")]
    )

    let item = HerdrTabBarProjection.items(
      in: snapshot,
      workspaceID: "w1",
      processInfoByPaneID: ["w1:p1": processInfo]
    ).first

    #expect(
      item?.processTitle
        == HerdrProcessTitle(
          processName: "lazygit",
          directoryName: "warlock-ios-simulator-replay ↳ Warlock",
          linkedWorktree: HerdrLinkedWorktreeTitle(
            repoName: "Warlock",
            checkoutName: "warlock-ios-simulator-replay"
          )
        )
    )
  }

  @Test func linkedWorktreeKeepsItsIdentityWhenNoForegroundProcessIsShown() {
    let worktree = HerdrWorkspaceWorktree(
      repoName: "Warlock",
      repoRoot: "/Users/yam/Developer/Warlock",
      checkoutPath: "/Users/yam/Developer/warlock-ios-simulator-replay",
      isLinkedWorktree: true
    )
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "w1:p1",
      workspaces: [HerdrWorkspace(workspaceID: "w1", worktree: worktree)],
      tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "feature")],
      panes: [HerdrPane(paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", focused: true)],
      layouts: [],
      agents: []
    )

    let item = HerdrTabBarProjection.items(in: snapshot, workspaceID: "w1").first

    #expect(item?.processTitle == nil)
    #expect(item?.displayLabel == "warlock-ios-simulator-replay ↳ Warlock")
  }

  @Test func nativeAggregateProjectionPreservesLinkedWorktreeTitle() throws {
    let snapshot = try JSONDecoder().decode(
      HerdrClientShellSnapshot.self,
      from: Data(
        #"""
        {
          "boot_id": "boot",
          "revision": 1,
          "focused_workspace_id": "w1",
          "focused_tab_id": "w1:t1",
          "focused_pane_id": "w1:p1",
          "workspaces": [{
            "workspace_id": "w1",
            "active_tab_id": "w1:t1",
            "number": 1,
            "label": "repo",
            "custom_label": false,
            "branch": "feature",
            "worktree": {
              "key": "repo-key",
              "label": "Repo",
              "repo_root": "/repo",
              "checkout_path": "/repo/feature",
              "is_linked_worktree": true
            },
            "focused": true,
            "agent_status": "Idle"
          }],
          "tabs": [{
            "tab_id": "w1:t1",
            "workspace_id": "w1",
            "number": 1,
            "label": "feature",
            "custom_label": false,
            "zoomed": false,
            "focused": true,
            "agent_status": "Idle"
          }],
          "panes": [{
            "pane_id": "w1:p1",
            "workspace_id": "w1",
            "tab_id": "w1:t1",
            "cwd": "/repo/feature",
            "foreground_cwd": "/repo/feature",
            "focused": true,
            "input_context": {"kind": "command_like", "agent": null, "shell": "zsh"}
          }],
          "agents": []
        }
        """#.utf8
      )
    )

    let item = HerdrTabBarProjection.items(
      in: snapshot.legacyProjection,
      workspaceID: "w1"
    ).first

    #expect(item?.displayLabel == "feature ↳ Repo")
  }

  @Test func suppressesShellAndStarshipOnlyForegroundJobs() {
    let processInfo = HerdrPaneProcessInfo(
      paneID: "w1:p1",
      shellPID: 10,
      foregroundProcessGroupID: 10,
      foregroundProcesses: [
        HerdrPaneProcess(pid: 10, name: "custom-shell", argv0: "custom-shell"),
        HerdrPaneProcess(pid: 11, name: "starship", argv0: "starship"),
      ]
    )

    #expect(
      HerdrTabBarProjection.processTitle(in: processInfo, fallbackDirectory: "/tmp/Prowl") == nil
    )
  }

  @Test func projectsProcessTitlesForEveryTab() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "w1:p1",
      workspaces: [],
      tabs: [
        HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "shell"),
        HerdrTab(tabID: "w1:t2", workspaceID: "w1", label: "other"),
      ],
      panes: [
        HerdrPane(
          paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", focused: true, cwd: "/tmp/shell"),
        HerdrPane(paneID: "w1:p2", workspaceID: "w1", tabID: "w1:t2", cwd: "/tmp/Prowl"),
      ],
      layouts: [],
      agents: []
    )
    let processInfoByPaneID = [
      "w1:p1": HerdrPaneProcessInfo(
        paneID: "w1:p1",
        foregroundProcessGroupID: 20,
        foregroundProcesses: [HerdrPaneProcess(pid: 20, name: "zsh")]
      ),
      "w1:p2": HerdrPaneProcessInfo(
        paneID: "w1:p2",
        foregroundProcessGroupID: 30,
        foregroundProcesses: [HerdrPaneProcess(pid: 30, name: "lazygit")]
      ),
    ]

    let items = HerdrTabBarProjection.items(
      in: snapshot,
      workspaceID: "w1",
      processInfoByPaneID: processInfoByPaneID
    )

    #expect(items.first?.processTitle == nil)
    #expect(
      items.last?.processTitle == HerdrProcessTitle(processName: "lazygit", directoryName: "Prowl"))
  }

  @Test func manualDirectoryNameOnlyReplacesTheDirectorySegment() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "w1:p1",
      workspaces: [],
      tabs: [
        HerdrTab(
          tabID: "w1:t1",
          workspaceID: "w1",
          label: "Backend",
          customName: "Backend"
        )
      ],
      panes: [
        HerdrPane(
          paneID: "w1:p1",
          workspaceID: "w1",
          tabID: "w1:t1",
          focused: true,
          cwd: "/Users/yam/Developer/Prowl"
        )
      ],
      layouts: [],
      agents: []
    )
    let processInfo = HerdrPaneProcessInfo(
      paneID: "w1:p1",
      shellPID: 10,
      foregroundProcessGroupID: 20,
      foregroundProcesses: [
        HerdrPaneProcess(pid: 10, name: "zsh", argv0: "/bin/zsh"),
        HerdrPaneProcess(pid: 20, name: "lazygit", argv0: "lazygit", cwd: "/tmp/Prowl"),
      ]
    )

    let item = HerdrTabBarProjection.items(
      in: snapshot,
      workspaceID: "w1",
      processInfoByPaneID: ["w1:p1": processInfo]
    ).first

    #expect(item?.customName == "Backend")
    #expect(item?.displayLabel == "lazygit ・ Backend")
  }

  @Test func serverLabelRendersAsDirectorySegment() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "w1:p1",
      workspaces: [],
      tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "Prowl")],
      panes: [
        HerdrPane(
          paneID: "w1:p1",
          workspaceID: "w1",
          tabID: "w1:t1",
          focused: true,
          cwd: "/tmp/Other"
        )
      ],
      layouts: [],
      agents: []
    )

    let item = HerdrTabBarProjection.items(in: snapshot, workspaceID: "w1").first

    #expect(item?.directoryLabel == "Prowl")
    #expect(item?.displayLabel == "Prowl")
  }

  @Test func linkedWorktreeDirectoryCanBeOverriddenAndRestored() {
    let worktree = HerdrWorkspaceWorktree(
      repoName: "Prowl",
      repoRoot: "/Users/yam/Developer/Prowl",
      checkoutPath: "/tmp/Prowl-feature",
      isLinkedWorktree: true
    )
    let base = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "w1:p1",
      workspaces: [HerdrWorkspace(workspaceID: "w1", worktree: worktree)],
      tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "1")],
      panes: [
        HerdrPane(paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", focused: true)
      ],
      layouts: [],
      agents: []
    )
    let overridden = HerdrSessionSnapshot(
      version: base.version,
      protocolVersion: base.protocolVersion,
      focusedWorkspaceID: base.focusedWorkspaceID,
      focusedTabID: base.focusedTabID,
      focusedPaneID: base.focusedPaneID,
      workspaces: base.workspaces,
      tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "Backend", customName: "Backend")],
      panes: base.panes,
      layouts: base.layouts,
      agents: base.agents
    )

    let automatic = HerdrTabBarProjection.items(in: base, workspaceID: "w1").first
    let manual = HerdrTabBarProjection.items(in: overridden, workspaceID: "w1").first

    #expect(automatic?.displayLabel == "Prowl-feature ↳ Prowl")
    #expect(manual?.displayLabel == "Backend")
  }

  @Test func prefersProjectedFocusedPaneOverStaleSnapshotFocus() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "w1:p1",
      workspaces: [],
      tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "shell")],
      panes: [
        HerdrPane(
          paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", focused: true, cwd: "/tmp/old"),
        HerdrPane(paneID: "w1:p2", workspaceID: "w1", tabID: "w1:t1", cwd: "/tmp/current"),
      ],
      layouts: [],
      agents: []
    )
    let processInfoByPaneID = [
      "w1:p1": HerdrPaneProcessInfo(
        paneID: "w1:p1",
        foregroundProcessGroupID: 20,
        foregroundProcesses: [HerdrPaneProcess(pid: 20, name: "python3")]
      ),
      "w1:p2": HerdrPaneProcessInfo(
        paneID: "w1:p2",
        foregroundProcessGroupID: 30,
        foregroundProcesses: [HerdrPaneProcess(pid: 30, name: "lazygit")]
      ),
    ]

    let item = HerdrTabBarProjection.items(
      in: snapshot,
      workspaceID: "w1",
      processInfoByPaneID: processInfoByPaneID,
      focusedPaneID: "w1:p2"
    ).first

    #expect(
      item?.processTitle == HerdrProcessTitle(processName: "lazygit", directoryName: "current"))
  }

  @Test func removesProcessTitleWhenTheForegroundJobReturnsToShell() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t1",
      focusedPaneID: "w1:p1",
      workspaces: [],
      tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "TikTok_foldable")],
      panes: [
        HerdrPane(
          paneID: "w1:p1",
          workspaceID: "w1",
          tabID: "w1:t1",
          focused: true,
          cwd: "/tmp/TikTok_foldable"
        )
      ],
      layouts: [],
      agents: []
    )
    let shellInfo = HerdrPaneProcessInfo(
      paneID: "w1:p1",
      shellPID: 10,
      foregroundProcessGroupID: 10,
      foregroundProcesses: [HerdrPaneProcess(pid: 10, name: "zsh", argv0: "/bin/zsh")]
    )

    let item = HerdrTabBarProjection.items(
      in: snapshot,
      workspaceID: "w1",
      processInfoByPaneID: ["w1:p1": shellInfo]
    ).first

    #expect(item?.processTitle == nil)
    #expect(item?.displayLabel == "TikTok_foldable")
  }

  @Test func suppressesEveryKnownAgentProcessName() {
    let processNames = HerdrTabAgentKind.allCases.flatMap(\.identifiers)

    for processName in processNames {
      let processInfo = HerdrPaneProcessInfo(
        paneID: "w1:p1",
        foregroundProcessGroupID: 20,
        foregroundProcesses: [HerdrPaneProcess(pid: 20, name: processName)]
      )

      #expect(
        HerdrTabBarProjection.processTitle(in: processInfo, fallbackDirectory: "/tmp/bb") == nil
      )
    }
  }

  @Test func usesCanonicalProviderAccentColors() {
    #expect(HerdrTabAgentKind.generic.accent == .systemSecondary)
    #expect(HerdrTabAgentKind.codex.accent == .systemPrimary)
    #expect(HerdrTabAgentKind.claude.accent == .claude)
    #expect(HerdrTabAgentKind.pi.accent == .pi)
    #expect(HerdrTabAgentKind.cursor.accent == .cursor)
    #expect(HerdrTabAgentKind.opencode.accent == .opencode)
    #expect(HerdrTabAgentKind.omp.accent == .omp)
    #expect(HerdrTabAgentKind.grok.accent == .systemPrimary)
    #expect(HerdrTabAgentKind.fx.accent == .systemPrimary)
  }

  @Test func computesServerInsertIndexBeforeDropTarget() {
    let items = [
      HerdrTabBarItem(id: "t1", workspaceID: "w1", label: "one", isZoomed: false, isFocused: true),
      HerdrTabBarItem(id: "t2", workspaceID: "w1", label: "two", isZoomed: false, isFocused: false),
      HerdrTabBarItem(
        id: "t3", workspaceID: "w1", label: "three", isZoomed: false, isFocused: false),
    ]

    #expect(
      HerdrTabBarProjection.insertIndex(sourceID: "t3", targetID: "t1", items: items) == 0
    )
    #expect(
      HerdrTabBarProjection.insertIndex(sourceID: "t2", targetID: "t3", items: items) == 2
    )
    #expect(
      HerdrTabBarProjection.insertIndex(sourceID: "t2", targetID: "t2", items: items) == nil
    )
  }

  @Test func cyclesTabsLikeHerdrMouseWheel() {
    let items = [
      HerdrTabBarItem(id: "t1", workspaceID: "w1", label: "one", isZoomed: false, isFocused: true),
      HerdrTabBarItem(id: "t2", workspaceID: "w1", label: "two", isZoomed: false, isFocused: false),
      HerdrTabBarItem(
        id: "t3", workspaceID: "w1", label: "three", isZoomed: false, isFocused: false),
    ]

    #expect(HerdrTabBarProjection.cycleTarget(selectedID: "t1", direction: 1, items: items) == "t2")
    #expect(
      HerdrTabBarProjection.cycleTarget(selectedID: "t1", direction: -1, items: items) == "t3")
  }

  @Test func showsActiveTreatmentForSelectedTabIncludingSingleTabWorkspaces() {
    let item = HerdrTabBarItem(
      id: "t1",
      workspaceID: "w1",
      label: "one",
      isZoomed: false,
      isFocused: true
    )

    #expect(
      HerdrTabBarProjection.shouldShowActiveTreatment(
        itemID: item.id, selectedID: item.id))
    #expect(
      HerdrTabBarProjection.shouldShowActiveTreatment(
        itemID: item.id, selectedID: item.id))
    #expect(
      !HerdrTabBarProjection.shouldShowActiveTreatment(
        itemID: "t2", selectedID: item.id))
  }

  @Test func usesCompactTabGeometryWithoutLeadingBarGap() {
    #expect(HerdrTabBarLayout.minimumTabWidth == 46)
    #expect(HerdrTabBarLayout.barLeadingPadding == 0)
    #expect(HerdrTabBarLayout.tabTextLeadingPadding == 18)
  }

  @Test func scrollsOnlyWhenSelectedTabIsOutsideTheVisibleSet() {
    #expect(
      !HerdrTabBarProjection.shouldScrollToSelected(
        selectedID: "t1", visibleIDs: ["t1", "t2"])
    )
    #expect(
      HerdrTabBarProjection.shouldScrollToSelected(
        selectedID: "t3", visibleIDs: ["t1", "t2"])
    )
  }
}
