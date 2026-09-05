import ComposableArchitecture
import SwiftUI

struct AgentIslandRosterLayout: Equatable {
  static let pageSize = AgentIslandNavigation.pageSize

  let pageIndex: Int
  let pageCount: Int
  let entryRange: Range<Int>

  static func layout(
    entryCount: Int,
    requestedPageIndex: Int
  ) -> Self {
    guard entryCount > 0 else {
      return Self(pageIndex: 0, pageCount: 0, entryRange: 0..<0)
    }
    let pageCount = Int(ceil(Double(entryCount) / Double(pageSize)))
    let pageIndex = min(max(0, requestedPageIndex), pageCount - 1)
    let lowerBound = pageIndex * pageSize
    return Self(
      pageIndex: pageIndex,
      pageCount: pageCount,
      entryRange: lowerBound..<min(lowerBound + pageSize, entryCount)
    )
  }
}

/// Agent Island's expanded roster, composed from the original Active Agents row.
struct AgentIslandRosterContent: View {
  @Bindable var store: StoreOf<ActiveAgentsFeature>
  let rowDisplays: [ActiveAgentEntry.ID: ActiveAgentRowDisplay]
  let workflowBadges: [UUID: String]
  let selectedSurfaceID: UUID?

  var body: some View {
    let layout = AgentIslandRosterLayout.layout(
      entryCount: store.entries.count,
      requestedPageIndex: store.islandNavigation.pageIndex
    )
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        if store.entries.isEmpty {
          Text("No running agents")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
        ForEach(Array(layout.entryRange.enumerated()), id: \.element) { visibleIndex, entryIndex in
          let entry = store.entries[entryIndex]
          Button {
            store.send(.island(.entryTapped(entry.id)))
          } label: {
            HStack(spacing: 4) {
              ActiveAgentRow(
                entry: entry,
                repositoryName: repositoryName(for: entry),
                subtitle: subtitle(for: entry),
                repositoryColor: repositoryColor(for: entry),
                isDimmed: isDimmed(entry)
              )
              ShortcutHintView(text: "\(visibleIndex + 1)", color: .secondary, font: .caption)
                .monospaced()
                .padding(.trailing, 10)
            }
            .background {
              if store.islandNavigation.selectedEntryID == entry.id {
                RoundedRectangle(cornerRadius: 7)
                  .fill(Color.accentColor.opacity(0.24))
                  .padding(.horizontal, 4)
              }
            }
          }
          .buttonStyle(.plain)
          .accessibilityValue(
            store.islandNavigation.selectedEntryID == entry.id ? "Selected" : ""
          )
          .contextMenu {
            ActiveAgentRowContextMenu(
              entry: entry,
              directory: rowDisplays[entry.id]?.directory,
              send: { store.send(.island($0)) }
            )
          }
        }
      }

      Divider()
      keyboardFooter(layout: layout)
    }
  }

  private func keyboardFooter(layout: AgentIslandRosterLayout) -> some View {
    VStack(spacing: 5) {
      if layout.pageCount > 1 {
        HStack(spacing: 8) {
          Button {
            store.send(.islandMovePage(.previous))
          } label: {
            Label("Previous page", systemImage: "chevron.left")
              .labelStyle(.iconOnly)
          }
          .buttonStyle(.borderless)
          .disabled(layout.pageIndex == 0)

          Text("\(layout.pageIndex + 1) / \(layout.pageCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

          Button {
            store.send(.islandMovePage(.next))
          } label: {
            Label("Next page", systemImage: "chevron.right")
              .labelStyle(.iconOnly)
          }
          .buttonStyle(.borderless)
          .disabled(layout.pageIndex == layout.pageCount - 1)
        }
        .frame(height: 24)
      }

      HStack(spacing: 14) {
        if !store.entries.isEmpty {
          keyboardLegend(keys: ["↑ K", "↓ J"], action: "Select")
        }
        if layout.pageCount > 1 {
          keyboardLegend(keys: ["← H", "→ L"], action: "Page")
        }
        if !store.entries.isEmpty {
          keyboardLegend(keys: ["↩", "Space"], action: "Open")
        }
        Spacer(minLength: 0)
        Button {
          store.send(.islandSettingsTapped)
        } label: {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
        .help("Open Settings → Agents → Display")
        .accessibilityLabel("Agent display settings")
        .accessibilityIdentifier("agent-island-settings")
      }
      .padding(.horizontal, 12)
      .frame(height: 24)
    }
    .padding(.vertical, 4)
  }

  private func keyboardLegend(keys: [String], action: String) -> some View {
    HStack(spacing: 4) {
      HStack(spacing: 2) {
        ForEach(keys, id: \.self) { key in
          ShortcutHintView(text: key, color: .primary)
            .monospaced()
        }
      }
      Text(action)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private func repositoryName(for entry: ActiveAgentEntry) -> String {
    rowDisplays[entry.id]?.repositoryName ?? entry.worktreeName
  }

  private func branchName(for entry: ActiveAgentEntry) -> String {
    rowDisplays[entry.id]?.branchName ?? entry.worktreeName
  }

  private func subtitle(for entry: ActiveAgentEntry) -> String {
    ActiveAgentRowPresentation.combinedSubtitle(
      for: entry,
      branchName: branchName(for: entry),
      workflowBadge: workflowBadges[entry.surfaceID]
    )
  }

  private func repositoryColor(for entry: ActiveAgentEntry) -> RepositoryColorChoice? {
    rowDisplays[entry.id]?.color
  }

  private func isDimmed(_ entry: ActiveAgentEntry) -> Bool {
    if let selectedEntryID = store.islandNavigation.selectedEntryID {
      return entry.id != selectedEntryID
    }
    return selectedSurfaceID.map { entry.surfaceID != $0 } ?? false
  }
}
