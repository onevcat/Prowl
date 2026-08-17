import SwiftUI

enum LeadingToolbarControlMetrics {
  static let labelSpacing: CGFloat = 6
  static let iconSize: CGFloat = 20
  static let font: Font = .title3.weight(.medium)
}

/// What the Agents capsule shows for the selected pane's detected agent.
/// nil means no detected agent: the capsule renders its generic form and the
/// popover offers launch rows when a target exists, otherwise management only
/// (docs-ai 053/058).
struct AgentsCapsuleState: Equatable {
  let displayName: String
  /// Resolved branded icon; nil falls back to a generic symbol. Resolved by
  /// the assembler with the same two-step token fallback the Active Agents
  /// panel uses, so a wrapper process name never loses the brand icon.
  let iconSource: TabIconSource?
  /// Plain-language explanation of the hand-off action, shown under its
  /// title in the popover row; varies with the source session's state.
  let infoLine: String
}

/// One launchable agent profile row in the Agents popover (docs-ai 053).
struct AgentsLauncherItem: Equatable, Identifiable {
  let id: AgentProfile.ID
  let name: String
  let runtimeName: String
  let iconSource: AgentProfileIconSource
  let isRecommended: Bool
  /// Soft availability warning ("Claude Code may not be installed"); nil = no
  /// concern. A warning dims the row but never disables it — the heuristic has
  /// false negatives (installed but never run, dedicated-home-only logins),
  /// and a wrong launch fails visibly in the new surface (docs-ai 053/005).
  let availabilityWarning: String?
}

/// Leading toolbar entry point for agent-scoped actions.
/// The capsule identifies the selected pane's agent (the hand-off source);
/// clicking it opens a popover that hosts the agent actions — hand-off when
/// an agent is detected, plus the profile launcher and the manage entry
/// (docs-ai 049/053). The popover is always available: launch rows require a
/// target worktree but never a detected agent, while profile management remains
/// available without either. Live status stays with the terminal, the Active
/// Agents panel, and the central status toast — the capsule deliberately
/// carries no state indicator. A `Menu` cannot host this control: macOS
/// toolbars flatten custom menu labels to their text, dropping the badge, so
/// the popover is the durable container here.
///
/// The button carries no background of its own: it sits in a shared-glass
/// toolbar group next to `AgentsQuickLaunchButton`. Notifications and update
/// status follow in an isolated glass capsule because adjacent navigation
/// groups merge on macOS 26. See docs-ai 061 before changing that composition.
/// Normal, Shelf, and Canvas share this leading structure.
struct AgentsToolbarButton: View {
  let capsule: AgentsCapsuleState?
  let launcherItems: [AgentsLauncherItem]
  let onHandOff: () -> Void
  let onLaunchProfile: (AgentProfile.ID) -> Void
  let onManageProfiles: () -> Void
  @State private var isPopoverPresented = false

  var body: some View {
    Button {
      isPopoverPresented.toggle()
    } label: {
      label
    }
    .help(helpText)
    .accessibilityLabel(accessibilityText)
    .accessibilityIdentifier("agents-toolbar-menu")
    .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
      AgentsPopoverContent(
        capsule: capsule,
        launcherItems: launcherItems,
        onHandOff: {
          isPopoverPresented = false
          onHandOff()
        },
        onLaunchProfile: { id in
          isPopoverPresented = false
          onLaunchProfile(id)
        },
        onManageProfiles: {
          isPopoverPresented = false
          onManageProfiles()
        }
      )
    }
  }

  /// Uses the established toolbar metrics (title3 medium, 20pt icon slot)
  /// so the capsule stays aligned with its neighboring controls.
  @ViewBuilder
  private var label: some View {
    HStack(spacing: LeadingToolbarControlMetrics.labelSpacing) {
      if let capsule {
        agentIcon(capsule)
          .frame(
            width: LeadingToolbarControlMetrics.iconSize,
            height: LeadingToolbarControlMetrics.iconSize
          )
        Text(capsule.displayName)
      } else {
        Image(systemName: "sparkles")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
          .frame(
            width: LeadingToolbarControlMetrics.iconSize,
            height: LeadingToolbarControlMetrics.iconSize
          )
        Text("Agents")
      }
    }
    .font(LeadingToolbarControlMetrics.font)
  }

  @ViewBuilder
  private func agentIcon(_ capsule: AgentsCapsuleState) -> some View {
    if let source = capsule.iconSource {
      TabIconImage(rawName: source.storageString, pointSize: 17)
    } else {
      Image(systemName: "sparkle")
        .accessibilityHidden(true)
    }
  }

  private var helpText: String {
    guard let capsule else {
      return launcherItems.isEmpty
        ? "Manage agent profiles"
        : "Launch an agent profile in this worktree"
    }
    return "Agent actions for \(capsule.displayName)"
  }

  private var accessibilityText: String {
    guard let capsule else { return "Agents" }
    return "Agents: \(capsule.displayName)"
  }
}

/// Quick-launch half of the Agents split control: one click starts the
/// Recommended profile — the launcher list's leading row (docs-ai 053) — so
/// the segment and the popover always agree on what it launches. Lives as its
/// own toolbar item in the Agents shared-glass group, which is what produces
/// the system split-button look (and per-segment hover) next to
/// `AgentsToolbarButton`.
struct AgentsQuickLaunchButton: View {
  let item: AgentsLauncherItem
  let onLaunch: (AgentProfile.ID) -> Void

  var body: some View {
    Button {
      onLaunch(item.id)
    } label: {
      Image(systemName: "play.circle")
        .font(LeadingToolbarControlMetrics.font)
        .foregroundStyle(.secondary)
    }
    .help("Launch \(item.name) in this worktree")
    .accessibilityLabel("Launch \(item.name)")
    .accessibilityIdentifier("agents-toolbar-quick-launch")
  }
}

/// The agent-actions popover. Hand-off leads when an agent is detected; the
/// launcher rows follow under one "New agent in this worktree" section header
/// (recommended profile first) so the shared purpose is stated once instead
/// of repeated per row, and the manage entry closes the list.
private struct AgentsPopoverContent: View {
  let capsule: AgentsCapsuleState?
  let launcherItems: [AgentsLauncherItem]
  let onHandOff: () -> Void
  let onLaunchProfile: (AgentProfile.ID) -> Void
  let onManageProfiles: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let capsule {
        AgentsPopoverRow(
          title: "Hand Off…",
          subtitle: capsule.infoLine,
          systemImage: "arrow.left.arrow.right",
          action: onHandOff
        )
        if !launcherItems.isEmpty {
          Divider().padding(.vertical, 4)
        }
      }
      if !launcherItems.isEmpty {
        Text("New agent in this worktree")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.top, 4)
          .padding(.bottom, 2)
        ForEach(launcherItems) { item in
          AgentsPopoverRow(
            title: item.isRecommended ? "\(item.name) ★" : item.name,
            subtitle: item.availabilityWarning,
            systemImage: "play.circle",
            iconSource: item.iconSource,
            trailingText: item.runtimeName,
            isDimmed: item.availabilityWarning != nil,
            action: { onLaunchProfile(item.id) }
          )
        }
      }
      if capsule != nil || !launcherItems.isEmpty {
        Divider().padding(.vertical, 4)
      }
      AgentsPopoverRow(
        title: "Manage Agent Profiles…",
        subtitle: "Add presets, models, and accounts in Settings",
        systemImage: "slider.horizontal.3",
        action: onManageProfiles
      )
    }
    .padding(6)
    .frame(width: 280, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Agents")
    .accessibilityIdentifier("agents-toolbar-popover")
    // Runtimes still warned about (or unanswered) re-probe on every open, so
    // a CLI installed mid-session clears its warning without a relaunch.
    .task { await AgentRuntimeAvailabilityProbe.refresh() }
  }
}

private struct AgentsPopoverRow: View {
  let title: String
  /// Second line under the title; nil keeps the row single-line. Launcher
  /// rows reserve it for availability warnings — their shared purpose lives
  /// in the section header above them.
  let subtitle: String?
  let systemImage: String
  var iconSource: AgentProfileIconSource?
  /// Small trailing annotation on the title line (the runtime's display name
  /// on launcher rows, so same-runtime profiles stay distinguishable).
  var trailingText: String?
  /// Dimmed rows carry an availability warning but stay fully clickable — the
  /// warning heuristic must never block a launch (docs-ai 053/005).
  var isDimmed: Bool = false
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 8) {
        if let iconSource {
          AgentProfileIconImage(source: iconSource, pointSize: 16)
            .frame(width: 16)
        } else {
          Image(systemName: systemImage)
            .frame(width: 16)
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
              .lineLimit(1)
            Spacer(minLength: 0)
            if let trailingText {
              Text(trailingText)
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }
          if let subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .opacity(isDimmed ? 0.5 : 1)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isHovered ? Color.accentColor.opacity(0.2) : Color.clear)
    )
    .onHover { isHovered = $0 }
  }
}
