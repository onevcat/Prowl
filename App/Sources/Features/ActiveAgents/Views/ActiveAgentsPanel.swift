import AppKit
import ComposableArchitecture
import SwiftUI

struct ActiveAgentsPanel: View {
  @Bindable var store: StoreOf<ActiveAgentsFeature>
  /// Per-entry repository/branch labels resolved from each agent's working directory by the parent
  /// (see `SidebarListView.activeAgentRowDisplays`); keeps this view presentational.
  let rowDisplays: [ActiveAgentEntry.ID: ActiveAgentRowDisplay]
  /// `in <workflow> · <role>` labels for panes bound to an active run, resolved by AppFeature
  /// (docs-ai 063 C2); replaces the branch/title subtitle while the run lives.
  let workflowBadges: [UUID: String]
  let selectedSurfaceID: UUID?
  /// Merged "⌥⌃↑↓" hint shown while Cmd is held; `nil` hides it (bindings customized
  /// or Cmd not held). Resolved by the parent so the panel stays presentational.
  let navigationShortcutHint: String?
  let isCommandKeyPressed: Bool
  let showTabTitles: Bool
  let showAgentNames: Bool
  let height: Double
  let maximumHeight: Double
  let onHeightChanged: (Double) -> Void
  let onHeightChangeEnded: (Double) -> Void
  @State private var dragStartHeight: Double?
  @State private var dragIndicatorPillOpacity: CGFloat = 0.4

  var body: some View {
    VStack(spacing: 0) {
      resizeHandle
      HStack {
        Text("Active Agents")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        ZStack(alignment: .trailing) {
          if isCommandKeyPressed {
            if let navigationShortcutHint, !store.entries.isEmpty {
              ShortcutHintView(text: navigationShortcutHint, color: .secondary)
                .transition(.opacity)
            }
          } else {
            Button {
              store.send(.islandToggleEnabledTapped)
            } label: {
              Image(systemName: "inset.filled.topthird.rectangle")
                .font(.caption)
                .foregroundStyle(store.isIslandEnabled ? .primary : .secondary)
                .frame(width: 20, height: 16)
            }
            .buttonStyle(.plain)
            .help(store.isIslandEnabled ? "Hide Agent Island" : "Show Agent Island")
            .accessibilityLabel("Show Agent Island")
            .accessibilityValue(store.isIslandEnabled ? "On" : "Off")
            .accessibilityIdentifier("active-agents-toggle-island")
            .transition(.opacity)
          }
        }
        .frame(height: 16)
      }
      .padding(.horizontal, 12)
      .padding(.top, 8)
      .padding(.bottom, 4)
      .animation(.easeInOut(duration: 0.15), value: isCommandKeyPressed)

      if store.entries.isEmpty {
        Spacer(minLength: 0)
        Text("New agents will appear here")
          .font(.callout)
          .foregroundStyle(.secondary)
          // Nudge up slightly off dead-center for better visual balance.
          .offset(y: -8)
        Spacer(minLength: 0)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(store.sections) { section in
              let isProjectSection = section.kind != .all
              if isProjectSection {
                sectionHeader(for: section)
              }
              ForEach(section.entryIDs, id: \.self) { entryID in
                if let entry = store.entries[id: entryID] {
                  row(for: entry, inProjectSection: isProjectSection)
                }
              }
            }
          }
        }
        .scrollIndicators(.never)
      }
    }
    .background {
      panelBackgroundShape
        .fill(.thinMaterial)
    }
    .clipShape(panelBackgroundShape)
  }

  private func row(for entry: ActiveAgentEntry, inProjectSection: Bool) -> some View {
    Button {
      store.send(.entryTapped(entry.id))
    } label: {
      ActiveAgentRow(
        entry: entry,
        repositoryName: repositoryName(for: entry),
        subtitle: subtitle(for: entry),
        repositoryColor: repositoryColor(for: entry),
        isDimmed: isDimmed(entry),
        showsAgentName: showAgentNames,
        showsRepositoryName: !inProjectSection
      )
    }
    .buttonStyle(.plain)
    .padding(.leading, inProjectSection ? 8 : 0)
    .help(helpText(for: entry))
    .contextMenu {
      ActiveAgentRowContextMenu(
        entry: entry,
        directory: rowDisplays[entry.id]?.directory,
        send: { store.send($0) }
      )
    }
  }

  /// A single-level project title (docs-ai 092). The rows of one project share the
  /// repository that they show, so the first row gives the name and the color.
  private func sectionHeader(for section: ActiveAgentSection) -> some View {
    let firstEntry = section.entryIDs.first.flatMap { store.entries[id: $0] }
    let isOther = section.kind == .other
    let title = isOther ? String(localized: "Other") : firstEntry.map(repositoryName(for:)) ?? ""
    let color = isOther ? nil : firstEntry.flatMap(repositoryColor(for:))
    return Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(color?.color ?? .secondary)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.top, 6)
      .padding(.bottom, 2)
      .accessibilityAddTraits(.isHeader)
  }

  private var resizeHandle: some View {
    Rectangle()
      .fill(.clear)
      .frame(height: 1)
      .frame(maxWidth: .infinity)
      .overlay(alignment: .top) {
        Capsule()
          .fill(.separator.opacity(dragIndicatorPillOpacity))
          .frame(width: 32, height: 4)
          .padding(.vertical, 4)
      }
      .overlay {
        Rectangle()
          .fill(.clear)
          .frame(height: 8)
          .contentShape(.rect)
      }
      .gesture(
        DragGesture(coordinateSpace: .global)
          .onChanged { value in
            let start = dragStartHeight ?? height
            dragStartHeight = start
            onHeightChanged(clampedHeight(start - value.translation.height))
            dragIndicatorPillOpacity = 0.8
          }
          .onEnded { value in
            let start = dragStartHeight ?? height
            let height = clampedHeight(start - value.translation.height)
            dragStartHeight = nil
            onHeightChangeEnded(height)
            dragIndicatorPillOpacity = 0.4
          }
      )
      .onHover { hovering in
        if hovering {
          NSCursor.resizeUpDown.set()
        } else {
          NSCursor.arrow.set()
        }
      }
  }

  private func clampedHeight(_ height: Double) -> Double {
    min(maximumHeight, max(ActiveAgentsFeature.minimumPanelHeight, height))
  }

  private func repositoryName(for entry: ActiveAgentEntry) -> String {
    rowDisplays[entry.id]?.repositoryName ?? entry.worktreeName
  }

  private func branchName(for entry: ActiveAgentEntry) -> String {
    rowDisplays[entry.id]?.branchName ?? entry.worktreeName
  }

  private func subtitle(for entry: ActiveAgentEntry) -> String {
    ActiveAgentRowPresentation.subtitle(
      for: entry,
      branchName: branchName(for: entry),
      showTabTitles: showTabTitles,
      workflowBadge: workflowBadges[entry.surfaceID]
    )
  }

  private func repositoryColor(for entry: ActiveAgentEntry) -> RepositoryColorChoice? {
    rowDisplays[entry.id]?.color
  }

  private func isDimmed(_ entry: ActiveAgentEntry) -> Bool {
    // Highlight the selected worktree's active surface. `entryTapped` now focuses
    // the target surface before selecting its worktree, so `selectedSurfaceID` is
    // already correct by the time the selection lands — no cross-worktree flash and
    // no dependence on the reducer's focus anchor, which can go stale when the
    // per-worktree `focusChanged` dedup suppresses an event.
    if let selectedSurfaceID {
      return entry.surfaceID != selectedSurfaceID
    }
    return false
  }

  private func helpText(for entry: ActiveAgentEntry) -> String {
    ActiveAgentRowPresentation.helpText(
      for: entry,
      branchName: branchName(for: entry),
      showTabTitles: showTabTitles,
      showAgentName: showAgentNames
    )
  }

  private var panelBackgroundShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 14)
  }
}
