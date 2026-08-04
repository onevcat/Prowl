import AppKit
import ComposableArchitecture
import SwiftUI

struct ActiveAgentsPanel: View {
  @Bindable var store: StoreOf<ActiveAgentsFeature>
  /// Per-entry repository/branch labels resolved from each agent's working directory by the parent
  /// (see `SidebarListView.activeAgentRowDisplays`); keeps this view presentational.
  let rowDisplays: [ActiveAgentEntry.ID: ActiveAgentRowDisplay]
  let selectedSurfaceID: UUID?
  /// Merged "⌥⌃↑↓" hint shown while Cmd is held; `nil` hides it (bindings customized
  /// or Cmd not held). Resolved by the parent so the panel stays presentational.
  let navigationShortcutHint: String?
  let showTabTitles: Bool
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
          .interfaceFont(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if let navigationShortcutHint, !store.entries.isEmpty {
          ShortcutHintView(text: navigationShortcutHint, color: .secondary)
            .transition(.opacity)
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 8)
      .padding(.bottom, 4)
      .animation(.easeInOut(duration: 0.15), value: navigationShortcutHint)

      if store.entries.isEmpty {
        Spacer(minLength: 0)
        Text("New agents will appear here")
          .interfaceFont(.callout)
          .foregroundStyle(.secondary)
          // Nudge up slightly off dead-center for better visual balance.
          .offset(y: -8)
        Spacer(minLength: 0)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(store.entries) { entry in
              Button {
                store.send(.entryTapped(entry.id))
              } label: {
                ActiveAgentRow(
                  entry: entry,
                  repositoryName: repositoryName(for: entry),
                  subtitle: subtitle(for: entry),
                  repositoryColor: repositoryColor(for: entry),
                  isDimmed: isDimmed(entry)
                )
              }
              .buttonStyle(.plain)
              .help(helpText(for: entry))
              .contextMenu {
                contextMenu(for: entry)
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

  @ViewBuilder
  private func contextMenu(for entry: ActiveAgentEntry) -> some View {
    Button("Hand Off…") {
      store.send(.handOffTapped(entry.id))
    }
    .help("Save this agent's progress and hand the task off to another agent")
    Button("Mark as Read") {
      store.send(.markAsReadTapped(entry.id))
    }
    .help("Clear this agent's unread notifications without switching to it")
    if let directory = rowDisplays[entry.id]?.directory {
      Divider()
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory.path, forType: .string)
      }
      .help("Copy the agent's working directory path")
      Button("Reveal in Finder") {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
      }
      .help("Reveal the agent's working directory in Finder")
    }
    if let transcriptPath = entry.session?.transcriptPath {
      Divider()
      Button("Copy Session Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptPath.path, forType: .string)
      }
      .help("Copy the on-disk path of this agent's session log")
      Button("Reveal Session in Finder") {
        NSWorkspace.shared.selectFile(
          transcriptPath.path,
          inFileViewerRootedAtPath: transcriptPath.deletingLastPathComponent().path
        )
      }
      .help("Select this agent's session log in Finder")
    }
  }

  private func repositoryName(for entry: ActiveAgentEntry) -> String {
    rowDisplays[entry.id]?.repositoryName ?? entry.worktreeName
  }

  private func branchName(for entry: ActiveAgentEntry) -> String {
    rowDisplays[entry.id]?.branchName ?? entry.worktreeName
  }

  private func subtitle(for entry: ActiveAgentEntry) -> String {
    Self.subtitle(
      for: entry,
      branchName: branchName(for: entry),
      showTabTitles: showTabTitles
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
    Self.helpText(
      for: entry,
      branchName: branchName(for: entry),
      showTabTitles: showTabTitles
    )
  }

  static func subtitle(
    for entry: ActiveAgentEntry,
    branchName: String,
    showTabTitles: Bool
  ) -> String {
    showTabTitles ? paneTitle(for: entry) : branchName
  }

  static func helpText(
    for entry: ActiveAgentEntry,
    branchName: String,
    showTabTitles: Bool
  ) -> String {
    showTabTitles ? branchName : paneTitle(for: entry)
  }

  static func paneTitle(for entry: ActiveAgentEntry) -> String {
    let trimmed = entry.paneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Untitled tab" : trimmed
  }

  private var panelBackgroundShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 14)
  }
}
