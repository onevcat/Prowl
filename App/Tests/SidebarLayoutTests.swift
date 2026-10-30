import Foundation
import Testing

@testable import Prowl

struct SidebarLayoutTests {
  private let groupA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
  private let groupB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

  @Test func repositoryIDsFlattenGroupsInPlace() {
    let layout = SidebarLayout(items: [
      .repository("/a"),
      .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b", "/c"])),
      .repository("/d"),
    ])

    #expect(layout.repositoryIDs == ["/a", "/b", "/c", "/d"])
    #expect(layout.groupID(containing: "/c") == groupA)
    #expect(layout.groupID(containing: "/a") == nil)
  }

  @Test func appendingMissingAddsOnlyUnknownRepositoriesToTheTopLevel() {
    let layout = SidebarLayout(items: [
      .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b"]))
    ])

    let result = layout.appendingMissing(["/a", "/b", "/c"])

    #expect(result.items.map(\.key) == [SidebarLayoutItem.groupKey(groupA), "/a", "/c"])
  }

  @Test func createGroupTakesTheTopLevelPlaceOfTheRepository() {
    var layout = SidebarLayout(repositoryIDs: ["/a", "/b", "/c"])

    layout.createGroup(id: groupA, title: "A", containing: "/b")

    #expect(
      layout.items == [
        .repository("/a"),
        .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b"])),
        .repository("/c"),
      ])
  }

  @Test func createGroupFromAGroupedRepositoryGoesAfterTheOldGroup() {
    var layout = SidebarLayout(items: [
      .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/a", "/b"])),
      .repository("/c"),
    ])

    layout.createGroup(id: groupB, title: "B", containing: "/a")

    #expect(
      layout.items == [
        .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b"])),
        .group(RepositoryGroup(id: groupB, title: "B", repositoryIDs: ["/a"])),
        .repository("/c"),
      ])
  }

  @Test func createGroupForAnUnknownRepositoryAppendsTheGroup() {
    var layout = SidebarLayout(repositoryIDs: ["/a"])

    layout.createGroup(id: groupA, title: "A", containing: "/z")

    #expect(layout.items.last == .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/z"])))
  }

  @Test func createEmptyGroupGoesToTheEndWithNoMembers() {
    let existing = RepositoryGroup(id: groupA, title: "Old", repositoryIDs: ["/b"])
    var layout = SidebarLayout(items: [.repository("/a"), .group(existing)])

    layout.createEmptyGroup(id: groupB, title: "New")

    #expect(
      layout.items == [
        .repository("/a"),
        .group(existing),
        .group(RepositoryGroup(id: groupB, title: "New")),
      ])
  }

  @Test func moveRepositoryToGroupAppendsItAndLeavesTheOldPlace() {
    var layout = SidebarLayout(items: [
      .repository("/a"),
      .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b"])),
      .group(RepositoryGroup(id: groupB, title: "B", repositoryIDs: ["/c"])),
    ])

    let result1 = layout.moveRepository("/a", toGroup: groupA)
    #expect(result1)
    let result2 = layout.moveRepository("/c", toGroup: groupA)
    #expect(result2)
    let result3 = layout.moveRepository("/c", toGroup: groupA)
    #expect(!result3)
    let result4 = layout.moveRepository("/b", toGroup: UUID())
    #expect(!result4)

    #expect(
      layout.items == [
        .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b", "/a", "/c"])),
        .group(RepositoryGroup(id: groupB, title: "B", repositoryIDs: [])),
      ])
  }

  @Test func removeFromGroupPutsTheRepositoryRightAfterTheGroup() {
    var layout = SidebarLayout(items: [
      .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/a", "/b"])),
      .repository("/c"),
    ])

    let result5 = layout.removeFromGroup("/a")
    #expect(result5)
    let result6 = layout.removeFromGroup("/c")
    #expect(!result6)

    #expect(
      layout.items == [
        .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b"])),
        .repository("/a"),
        .repository("/c"),
      ])
  }

  @Test func ungroupPutsTheMembersAtTheGroupPlace() {
    var layout = SidebarLayout(items: [
      .repository("/a"),
      .group(RepositoryGroup(id: groupA, title: "A", color: .blue, repositoryIDs: ["/b", "/c"])),
      .repository("/d"),
    ])

    let result7 = layout.ungroup(groupA)
    #expect(result7)
    let result8 = layout.ungroup(groupA)
    #expect(!result8)

    #expect(layout == SidebarLayout(repositoryIDs: ["/a", "/b", "/c", "/d"]))
  }

  @Test func renameAndColorChangeOnlyTheGroup() {
    var layout = SidebarLayout(items: [
      .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/a"]))
    ])

    let result9 = layout.renameGroup(groupA, to: "Product")
    #expect(result9)
    let result10 = layout.setGroupColor(groupA, to: .green)
    #expect(result10)
    let result11 = layout.renameGroup(groupB, to: "Other")
    #expect(!result11)

    #expect(
      layout.group(id: groupA) == RepositoryGroup(id: groupA, title: "Product", color: .green, repositoryIDs: ["/a"]))
  }

  @Test func setGroupIconChangesOnlyTheGroup() {
    var layout = SidebarLayout(items: [
      .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/a"]))
    ])

    let setIcon = layout.setGroupIcon(groupA, to: .sfSymbol("star.fill"))
    #expect(setIcon)
    let setMissing = layout.setGroupIcon(groupB, to: .sfSymbol("star.fill"))
    #expect(!setMissing)

    #expect(
      layout.group(id: groupA)
        == RepositoryGroup(id: groupA, title: "A", icon: .sfSymbol("star.fill"), repositoryIDs: ["/a"]))
  }

  // MARK: - Drag and drop moves (S2)

  private var groupKeyA: String { SidebarLayoutItem.groupKey(groupA) }
  private var groupKeyB: String { SidebarLayoutItem.groupKey(groupB) }

  private func dragLayout() -> SidebarLayout {
    SidebarLayout(items: [
      .repository("/a"),
      .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b", "/c"])),
      .repository("/d"),
      .group(RepositoryGroup(id: groupB, title: "B", repositoryIDs: [])),
    ])
  }

  @Test func moveReordersATopLevelRepository() {
    var layout = dragLayout()

    let moved1 = layout.move(.repository("/d"), to: .topLevel(before: "/a"))
    #expect(moved1)

    #expect(layout.items.map(\.key) == ["/d", "/a", groupKeyA, groupKeyB])
  }

  @Test func moveToTheTopLevelEndAppendsTheRepository() {
    var layout = dragLayout()

    let moved2 = layout.move(.repository("/a"), to: .topLevel(before: nil))
    #expect(moved2)

    #expect(layout.items.map(\.key) == [groupKeyA, "/d", groupKeyB, "/a"])
  }

  @Test func moveReordersMembersInAGroup() {
    var layout = dragLayout()

    let moved3 = layout.move(.repository("/c"), to: .group(groupA, before: "/b"))
    #expect(moved3)

    #expect(layout.group(id: groupA)?.repositoryIDs == ["/c", "/b"])
    #expect(layout.items.map(\.key) == ["/a", groupKeyA, "/d", groupKeyB])
  }

  @Test func moveIntoAGroupTakesTheRepositoryFromTheTopLevel() {
    var layout = dragLayout()

    let moved4 = layout.move(.repository("/a"), to: .group(groupA, before: "/c"))
    #expect(moved4)

    #expect(layout.group(id: groupA)?.repositoryIDs == ["/b", "/a", "/c"])
    #expect(layout.items.map(\.key) == [groupKeyA, "/d", groupKeyB])
  }

  @Test func moveToTheGroupEndFillsAnEmptyGroup() {
    var layout = dragLayout()

    let moved5 = layout.move(.repository("/b"), to: .group(groupB, before: nil))
    #expect(moved5)

    #expect(layout.group(id: groupA)?.repositoryIDs == ["/c"])
    #expect(layout.group(id: groupB)?.repositoryIDs == ["/b"])
  }

  @Test func moveOutOfAGroupKeepsTheEmptiedGroup() {
    var layout = SidebarLayout(items: [
      .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b"])),
      .repository("/d"),
    ])

    let moved6 = layout.move(.repository("/b"), to: .topLevel(before: groupKeyA))
    #expect(moved6)

    #expect(
      layout.items == [
        .repository("/b"),
        .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: [])),
        .repository("/d"),
      ])
  }

  @Test func moveReordersAWholeGroup() {
    var layout = dragLayout()

    let moved7 = layout.move(.group(groupA), to: .topLevel(before: nil))
    #expect(moved7)
    #expect(layout.items.map(\.key) == ["/a", "/d", groupKeyB, groupKeyA])

    let moved8 = layout.move(.group(groupA), to: .topLevel(before: "/a"))
    #expect(moved8)
    #expect(layout.items.map(\.key) == [groupKeyA, "/a", "/d", groupKeyB])
    #expect(layout.group(id: groupA)?.repositoryIDs == ["/b", "/c"])
  }

  @Test func aGroupDoesNotGoIntoAGroup() {
    var layout = dragLayout()

    let moved9 = layout.move(.group(groupB), to: .group(groupA, before: nil))
    #expect(!moved9)
    let moved10 = layout.move(.group(groupA), to: .group(groupA, before: "/b"))
    #expect(!moved10)

    #expect(layout == dragLayout())
  }

  @Test func aDropAtTheCurrentPlaceChangesNothing() {
    var layout = dragLayout()

    let moved11 = layout.move(.repository("/a"), to: .topLevel(before: "/a"))
    #expect(!moved11)
    let moved12 = layout.move(.repository("/a"), to: .topLevel(before: groupKeyA))
    #expect(!moved12)
    let moved13 = layout.move(.repository("/b"), to: .group(groupA, before: "/c"))
    #expect(!moved13)
    let moved14 = layout.move(.repository("/c"), to: .group(groupA, before: nil))
    #expect(!moved14)
    let moved15 = layout.move(.group(groupA), to: .topLevel(before: "/d"))
    #expect(!moved15)
    let moved16 = layout.move(.group(groupB), to: .topLevel(before: nil))
    #expect(!moved16)

    #expect(layout == dragLayout())
  }

  @Test func aDropOnAMissingAnchorOrItemChangesNothing() {
    var layout = dragLayout()

    let moved17 = layout.move(.repository("/a"), to: .topLevel(before: "/missing"))
    #expect(!moved17)
    let moved18 = layout.move(.repository("/a"), to: .group(groupA, before: "/d"))
    #expect(!moved18)
    let moved19 = layout.move(.repository("/a"), to: .group(UUID(), before: nil))
    #expect(!moved19)
    let moved20 = layout.move(.repository("/missing"), to: .topLevel(before: nil))
    #expect(!moved20)
    let moved21 = layout.move(.group(UUID()), to: .topLevel(before: nil))
    #expect(!moved21)

    #expect(layout == dragLayout())
  }

  @Test func moveKeepsTheRelativeOrderOfHiddenItems() {
    var layout = SidebarLayout(items: [
      .repository("/a"),
      .repository("ssh:hidden:/x"),
      .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b", "ssh:hidden:/y", "/c"])),
      .repository("/d"),
    ])

    let moved22 = layout.move(.repository("/d"), to: .topLevel(before: "/a"))
    #expect(moved22)
    let moved23 = layout.move(.repository("/c"), to: .group(groupA, before: "/b"))
    #expect(moved23)

    #expect(
      layout.items == [
        .repository("/d"),
        .repository("/a"),
        .repository("ssh:hidden:/x"),
        .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/c", "/b", "ssh:hidden:/y"])),
      ])
  }

  @Test func removeRepositoriesPrunesGroupMembersAndKeepsEmptyGroups() {
    var layout = SidebarLayout(items: [
      .repository("/a"),
      .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b"])),
    ])

    let result12 = layout.removeRepositories { $0 != "/a" }
    #expect(result12)
    let result13 = layout.removeRepositories { $0 != "/a" }
    #expect(!result13)

    #expect(
      layout.items == [
        .repository("/a"),
        .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: [])),
      ])
  }

  @Test func normalizedDropsDuplicatesAndFillsEmptyTitles() {
    let layout = SidebarLayout(items: [
      .repository("/a"),
      .group(RepositoryGroup(id: groupA, title: "  ", repositoryIDs: ["/a", "/b", "/b"])),
      .group(RepositoryGroup(id: groupA, title: "Again", repositoryIDs: ["/c"])),
      .repository("/b"),
    ])

    #expect(
      layout.normalized().items == [
        .repository("/a"),
        .group(RepositoryGroup(id: groupA, title: "Group", repositoryIDs: ["/b"])),
      ])
  }

  @Test func codableRoundTripUsesReadableItems() throws {
    let layout = SidebarLayout(items: [
      .repository("/a"),
      .group(RepositoryGroup(id: groupA, title: "A", color: .blue, repositoryIDs: ["/b"])),
      .group(
        RepositoryGroup(id: groupB, title: "B", icon: .userImage(filename: "b.svg"), repositoryIDs: [])),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let data = try encoder.encode(layout)
    let json = try #require(String(bytes: data, encoding: .utf8))

    #expect(json.contains(#"{"id":"\/a","type":"repository"}"#))
    #expect(json.contains(#""type":"group""#))
    #expect(json.contains(#""icon":"@file:b.svg""#))
    #expect(try JSONDecoder().decode(SidebarLayout.self, from: data) == layout)
  }

  @Test func decodingSkipsUnknownItemsAndKeepsGroupsWithAnUnknownColor() throws {
    let json = """
      {"items": [
        {"type": "repository", "id": "/a"},
        {"type": "folder", "id": "/x"},
        {"type": "group", "id": "00000000-0000-0000-0000-00000000000A", "title": "A", "color": "teal",
         "repositoryIDs": ["/b"]}
      ]}
      """

    let layout = try JSONDecoder().decode(SidebarLayout.self, from: Data(json.utf8))

    #expect(
      layout.items == [
        .repository("/a"),
        .group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b"])),
      ])
  }

  @Test func decodingKeepsAGroupWithABlankIcon() throws {
    let json = """
      {"items": [
        {"type": "group", "id": "00000000-0000-0000-0000-00000000000A", "title": "A", "icon": " ",
         "repositoryIDs": ["/b"]}
      ]}
      """

    let layout = try JSONDecoder().decode(SidebarLayout.self, from: Data(json.utf8))

    #expect(layout.items == [.group(RepositoryGroup(id: groupA, title: "A", repositoryIDs: ["/b"]))])
  }

  @Test func normalizedTitleTrimsAndRejectsBlank() {
    #expect(RepositoryGroup.normalizedTitle("  Product A ") == "Product A")
    #expect(RepositoryGroup.normalizedTitle(" \n ") == nil)
  }
}
