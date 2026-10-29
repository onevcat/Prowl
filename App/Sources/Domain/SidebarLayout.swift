import Foundation

/// A named group of repositories in the sidebar (docs-ai 086). A group holds
/// repositories only; groups do not nest.
nonisolated struct RepositoryGroup: Codable, Equatable, Hashable, Identifiable, Sendable {
  let id: UUID
  var title: String
  var color: RepositoryColorChoice?
  var repositoryIDs: [Repository.ID]

  init(
    id: UUID,
    title: String,
    color: RepositoryColorChoice? = nil,
    repositoryIDs: [Repository.ID] = []
  ) {
    self.id = id
    self.title = title
    self.color = color
    self.repositoryIDs = repositoryIDs
  }

  /// `title` without surrounding whitespace, or nil when nothing is left.
  static func normalizedTitle(_ title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// One top-level entry of the sidebar: an ungrouped repository or a group.
nonisolated enum SidebarLayoutItem: Equatable, Hashable, Sendable {
  case repository(Repository.ID)
  case group(RepositoryGroup)

  /// The identity of this entry in the top-level order. A group key cannot
  /// collide with a repository ID, which is a path or an `ssh:` ID.
  var key: String {
    switch self {
    case .repository(let id): id
    case .group(let group): Self.groupKey(group.id)
    }
  }

  static func groupKey(_ id: RepositoryGroup.ID) -> String {
    "group:\(id.uuidString)"
  }

  var repositoryIDs: [Repository.ID] {
    switch self {
    case .repository(let id): [id]
    case .group(let group): group.repositoryIDs
    }
  }
}

extension SidebarLayoutItem: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case id
    case title
    case color
    case repositoryIDs
  }

  private enum Kind: String, Codable {
    case repository
    case group
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .repository:
      self = .repository(try container.decode(Repository.ID.self, forKey: .id))
    case .group:
      self = .group(
        RepositoryGroup(
          id: try container.decode(UUID.self, forKey: .id),
          title: try container.decode(String.self, forKey: .title),
          // An unknown color must not drop the whole group.
          color: (try? container.decodeIfPresent(RepositoryColorChoice.self, forKey: .color)) ?? nil,
          repositoryIDs: try container.decodeIfPresent([Repository.ID].self, forKey: .repositoryIDs) ?? []
        ))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .repository(let id):
      try container.encode(Kind.repository, forKey: .type)
      try container.encode(id, forKey: .id)
    case .group(let group):
      try container.encode(Kind.group, forKey: .type)
      try container.encode(group.id, forKey: .id)
      try container.encode(group.title, forKey: .title)
      try container.encodeIfPresent(group.color, forKey: .color)
      try container.encode(group.repositoryIDs, forKey: .repositoryIDs)
    }
  }
}

/// The sidebar order: ungrouped repositories and groups at the top level. It is
/// the only source of repository order (docs-ai 086). A repository that is not
/// in the layout shows at the end of the top level.
nonisolated struct SidebarLayout: Codable, Equatable, Hashable, Sendable {
  var items: [SidebarLayoutItem]

  private enum CodingKeys: String, CodingKey {
    case items
  }

  /// Skips an item that does not decode, so one bad item does not drop the
  /// other groups.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var itemsContainer = try container.nestedUnkeyedContainer(forKey: .items)
    var items: [SidebarLayoutItem] = []
    while !itemsContainer.isAtEnd {
      if let item = try? itemsContainer.decode(SidebarLayoutItem.self) {
        items.append(item)
      } else {
        _ = try itemsContainer.decode(SkippedItem.self)
      }
    }
    self.items = items
  }

  private struct SkippedItem: Decodable {}

  init(items: [SidebarLayoutItem] = []) {
    self.items = items
  }

  init(repositoryIDs: [Repository.ID]) {
    self.items = repositoryIDs.map(SidebarLayoutItem.repository)
  }

  /// Every repository ID in sidebar order, group members in place.
  var repositoryIDs: [Repository.ID] {
    items.flatMap(\.repositoryIDs)
  }

  var groups: [RepositoryGroup] {
    items.compactMap {
      guard case .group(let group) = $0 else { return nil }
      return group
    }
  }

  func group(id: RepositoryGroup.ID) -> RepositoryGroup? {
    groups.first { $0.id == id }
  }

  func groupID(containing repositoryID: Repository.ID) -> RepositoryGroup.ID? {
    groups.first { $0.repositoryIDs.contains(repositoryID) }?.id
  }

  /// This layout with each of `repositoryIDs` that it does not hold appended to the top level.
  func appendingMissing(_ repositoryIDs: [Repository.ID]) -> SidebarLayout {
    var known = Set(self.repositoryIDs)
    var layout = self
    for id in repositoryIDs where known.insert(id).inserted {
      layout.items.append(.repository(id))
    }
    return layout
  }

  /// Puts `repositoryID` into a new group at its place. A repository in a group
  /// leaves that group, and the new group goes after it.
  mutating func createGroup(
    id: RepositoryGroup.ID,
    title: String,
    containing repositoryID: Repository.ID
  ) {
    let group = SidebarLayoutItem.group(RepositoryGroup(id: id, title: title, repositoryIDs: [repositoryID]))
    let index = topLevelIndex(of: repositoryID)
    let wasTopLevel = index.map { items[$0] == .repository(repositoryID) } ?? false
    removeRepository(repositoryID)
    guard let index else {
      items.append(group)
      return
    }
    items.insert(group, at: wasTopLevel ? index : index + 1)
  }

  /// Moves `repositoryID` to the end of the group. Returns false when the group
  /// does not exist or already holds it.
  @discardableResult
  mutating func moveRepository(_ repositoryID: Repository.ID, toGroup groupID: RepositoryGroup.ID) -> Bool {
    guard let group = group(id: groupID), !group.repositoryIDs.contains(repositoryID) else { return false }
    removeRepository(repositoryID)
    updateGroup(groupID) { $0.repositoryIDs.append(repositoryID) }
    return true
  }

  /// Moves `repositoryID` out of its group to the top level, right after the group.
  @discardableResult
  mutating func removeFromGroup(_ repositoryID: Repository.ID) -> Bool {
    guard let groupID = groupID(containing: repositoryID),
      let index = items.firstIndex(where: { $0.key == SidebarLayoutItem.groupKey(groupID) })
    else { return false }
    updateGroup(groupID) { $0.repositoryIDs.removeAll { $0 == repositoryID } }
    items.insert(.repository(repositoryID), at: index + 1)
    return true
  }

  @discardableResult
  mutating func renameGroup(_ groupID: RepositoryGroup.ID, to title: String) -> Bool {
    updateGroup(groupID) { $0.title = title }
  }

  @discardableResult
  mutating func setGroupColor(_ groupID: RepositoryGroup.ID, to color: RepositoryColorChoice?) -> Bool {
    updateGroup(groupID) { $0.color = color }
  }

  /// Removes the group and puts its members at its place. No repository is removed.
  @discardableResult
  mutating func ungroup(_ groupID: RepositoryGroup.ID) -> Bool {
    guard let index = items.firstIndex(where: { $0.key == SidebarLayoutItem.groupKey(groupID) }),
      case .group(let group) = items[index]
    else { return false }
    items.replaceSubrange(index...index, with: group.repositoryIDs.map(SidebarLayoutItem.repository))
    return true
  }

  /// Moves top-level items within `visibleKeys`, the top-level keys that the
  /// sidebar shows, in their shown order. Items that the sidebar does not show,
  /// such as hidden remote folders, keep their places.
  mutating func moveTopLevelItems(visibleKeys: [String], fromOffsets source: IndexSet, toOffset destination: Int) {
    let sourceIndexes = source.sorted().filter { visibleKeys.indices.contains($0) }
    var movedKeys = visibleKeys
    for index in sourceIndexes.reversed() {
      movedKeys.remove(at: index)
    }
    let insertionIndex = min(destination, visibleKeys.count) - sourceIndexes.count(where: { $0 < destination })
    movedKeys.insert(contentsOf: sourceIndexes.map { visibleKeys[$0] }, at: max(0, insertionIndex))
    let visible = Set(movedKeys)
    var mergedKeys = movedKeys
    for (index, item) in items.enumerated() where !visible.contains(item.key) {
      mergedKeys.insert(item.key, at: min(index, mergedKeys.count))
    }
    let itemsByKey = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    items = mergedKeys.compactMap { itemsByKey[$0] }
  }

  /// Removes the repositories that `isRemoved` matches, also from groups. Groups
  /// stay, even when empty. Returns whether anything changed.
  @discardableResult
  mutating func removeRepositories(where isRemoved: (Repository.ID) -> Bool) -> Bool {
    var pruned: [SidebarLayoutItem] = []
    for item in items {
      switch item {
      case .repository(let id):
        if !isRemoved(id) { pruned.append(item) }
      case .group(var group):
        group.repositoryIDs.removeAll(where: isRemoved)
        pruned.append(.group(group))
      }
    }
    guard pruned != items else { return false }
    items = pruned
    return true
  }

  /// Normalizes the stored IDs and keeps the first place of a repository or a group
  /// that occurs more than one time. A group with an empty title gets a default title.
  func normalized() -> SidebarLayout {
    var seenRepositories = Set<Repository.ID>()
    var seenGroups = Set<RepositoryGroup.ID>()
    var normalizedItems: [SidebarLayoutItem] = []
    func firstOccurrences(_ ids: [Repository.ID]) -> [Repository.ID] {
      RepositoryIDNormalizer.normalize(ids).filter { seenRepositories.insert($0).inserted }
    }
    for item in items {
      switch item {
      case .repository(let id):
        normalizedItems.append(contentsOf: firstOccurrences([id]).map(SidebarLayoutItem.repository))
      case .group(var group):
        guard seenGroups.insert(group.id).inserted else { continue }
        group.title = RepositoryGroup.normalizedTitle(group.title) ?? String(localized: "Group")
        group.repositoryIDs = firstOccurrences(group.repositoryIDs)
        normalizedItems.append(.group(group))
      }
    }
    return SidebarLayout(items: normalizedItems)
  }

  private func topLevelIndex(of repositoryID: Repository.ID) -> Int? {
    items.firstIndex { $0.repositoryIDs.contains(repositoryID) }
  }

  private mutating func removeRepository(_ repositoryID: Repository.ID) {
    removeRepositories { $0 == repositoryID }
  }

  @discardableResult
  private mutating func updateGroup(_ groupID: RepositoryGroup.ID, _ update: (inout RepositoryGroup) -> Void) -> Bool {
    guard let index = items.firstIndex(where: { $0.key == SidebarLayoutItem.groupKey(groupID) }),
      case .group(var group) = items[index]
    else { return false }
    update(&group)
    items[index] = .group(group)
    return true
  }
}
