import Foundation
import Testing

@testable import Prowl

struct SidebarExpansionStateTests {
  private let groupG = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
  private let groupH = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

  private func makeState(
    groups: [RepositoryGroup],
    expandable: Set<Repository.ID>,
    active: Set<Repository.ID> = [],
    expanded: Set<Repository.ID>,
    collapsedGroups: Set<RepositoryGroup.ID>
  ) -> SidebarListView.SidebarExpansionState {
    SidebarListView.SidebarExpansionState(
      groups: groups,
      expandableRepositoryIDs: expandable,
      activeRepositoryIDs: active,
      expandedRepositoryIDs: expanded,
      collapsedGroupIDs: collapsedGroups
    )
  }

  /// RG-001: with every group shut, members that keep their own expansion do not count,
  /// so the toggle offers an expand action, not a Collapse All that does nothing visible.
  @Test func membersOfShutGroupsDoNotCountAsExpanded() {
    let state = makeState(
      groups: [RepositoryGroup(id: groupG, title: "G", repositoryIDs: ["/a"])],
      expandable: ["/a"],
      expanded: ["/a"],
      collapsedGroups: [groupG]
    )

    #expect(state.headerAction == .expandAll)
  }

  @Test func collapseAllShutsGroupsAndRepositories() {
    let state = makeState(
      groups: [RepositoryGroup(id: groupG, title: "G", repositoryIDs: ["/a"])],
      expandable: ["/a", "/b"],
      expanded: ["/a", "/b"],
      collapsedGroups: []
    )

    #expect(state.headerAction == .collapseAll)
    let result = state.applying(.collapseAll)
    #expect(result.expandedRepositoryIDs.isEmpty)
    #expect(result.collapsedGroupIDs == [groupG])
  }

  @Test func expandAllOpensGroupsAndRepositories() {
    let state = makeState(
      groups: [RepositoryGroup(id: groupG, title: "G", repositoryIDs: ["/a"])],
      expandable: ["/a", "/b"],
      expanded: [],
      collapsedGroups: [groupG]
    )

    let result = state.applying(.expandAll)
    #expect(result.expandedRepositoryIDs == ["/a", "/b"])
    #expect(result.collapsedGroupIDs.isEmpty)
  }

  /// RG-002: a group whose only active member is a plain folder is active.
  @Test func expandActiveOpensTheGroupOfAnActivePlainFolder() {
    let state = makeState(
      groups: [
        RepositoryGroup(id: groupG, title: "G", repositoryIDs: ["/plain"]),
        RepositoryGroup(id: groupH, title: "H", repositoryIDs: ["/idle"]),
      ],
      expandable: ["/idle"],
      active: ["/plain"],
      expanded: [],
      collapsedGroups: [groupG, groupH]
    )

    #expect(state.headerAction == .expandActive)
    let result = state.applying(.expandActive)
    #expect(result.collapsedGroupIDs == [groupH])
    #expect(result.expandedRepositoryIDs.isEmpty)
  }

  @Test func withoutGroupsTheCycleIsUnchanged() {
    let state = makeState(
      groups: [],
      expandable: ["/a", "/b"],
      active: ["/a"],
      expanded: [],
      collapsedGroups: []
    )

    #expect(state.headerAction == .expandActive)
    let result = state.applying(.expandActive)
    #expect(result.expandedRepositoryIDs == ["/a"])
    #expect(result.collapsedGroupIDs.isEmpty)
  }
}
