import Foundation
import IdentifiedCollections
import Testing

@testable import Prowl

@MainActor
struct SettingsRepositoryListItemTests {
  private let groupID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

  @Test func ungroupedRepositoriesFollowTheSidebarOrder() {
    let repoA = makeRepository(id: "/tmp/a")
    let repoB = makeRepository(id: "/tmp/b")
    let repoC = makeRepository(id: "/tmp/c")
    var state = makeState(repositories: [repoA, repoB, repoC])
    state.sidebarLayout = SidebarLayout(repositoryIDs: [repoC.id, repoA.id, repoB.id])

    #expect(
      state.settingsRepositoryListItems() == [
        .repository(repoC.id),
        .repository(repoA.id),
        .repository(repoB.id),
      ]
    )
  }

  @Test func groupsKeepTheirPlaceAndMemberOrder() {
    let repoA = makeRepository(id: "/tmp/a")
    let repoB = makeRepository(id: "/tmp/b")
    let repoC = makeRepository(id: "/tmp/c")
    var state = makeState(repositories: [repoA, repoB, repoC])
    state.sidebarLayout = SidebarLayout(items: [
      .repository(repoB.id),
      .group(RepositoryGroup(id: groupID, title: "Product", repositoryIDs: [repoC.id, repoA.id])),
    ])

    #expect(
      state.settingsRepositoryListItems() == [
        .repository(repoB.id),
        .group(id: groupID, title: "Product", repositoryIDs: [repoC.id, repoA.id]),
      ]
    )
  }

  @Test func skipsRepositoriesThatAreNotLoadedAndGroupsLeftEmpty() {
    let repoA = makeRepository(id: "/tmp/a")
    var state = makeState(repositories: [repoA])
    state.repositoryRoots.append(.local(URL(fileURLWithPath: "/tmp/failed")))
    state.sidebarLayout = SidebarLayout(items: [
      .repository("/tmp/failed"),
      .group(RepositoryGroup(id: groupID, title: "Empty", repositoryIDs: ["/tmp/gone"])),
      .repository(repoA.id),
    ])

    #expect(state.settingsRepositoryListItems() == [.repository(repoA.id)])
  }

  @Test func appendsLoadedRepositoriesThatTheLayoutDoesNotHold() {
    let repoA = makeRepository(id: "/tmp/a")
    let repoB = makeRepository(id: "/tmp/b")
    var state = makeState(repositories: [repoA, repoB])
    state.repositoryRoots = [repoA.location]
    state.sidebarLayout = SidebarLayout(repositoryIDs: [repoA.id])

    #expect(
      state.settingsRepositoryListItems() == [
        .repository(repoA.id),
        .repository(repoB.id),
      ]
    )
  }

  @Test func listsEachRepositoryOnce() {
    let repoA = makeRepository(id: "/tmp/a")
    var state = makeState(repositories: [repoA])
    state.sidebarLayout = SidebarLayout(items: [
      .repository(repoA.id),
      .group(RepositoryGroup(id: groupID, title: "Product", repositoryIDs: [repoA.id])),
    ])

    #expect(state.settingsRepositoryListItems() == [.repository(repoA.id)])
  }

  private func makeRepository(id: String) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      kind: .git,
      worktrees: []
    )
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: repositories)
    state.repositoryRoots = repositories.map(\.location)
    return state
  }
}
