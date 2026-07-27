import SwiftUI

/// What the Agents capsule shows for the selected pane's detected agent.
/// nil means no agent: the capsule renders its generic, disabled form
/// (reserved for the future quick launcher — docs-ai 049).
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

/// Toolbar entry point for agent-scoped actions, left of the branch title.
/// The capsule identifies the selected pane's agent (the hand-off source);
/// clicking it opens a popover that hosts the agent actions — hand-off
/// today, more later (docs-ai 049). Live status stays with the terminal,
/// the Active Agents panel, and the central status toast — the capsule
/// deliberately carries no state indicator. A `Menu` cannot host this
/// control: macOS toolbars flatten custom menu labels to their text,
/// dropping the badge, so the popover is the durable container here.
struct AgentsToolbarButton: View {
  let capsule: AgentsCapsuleState?
  let onHandOff: () -> Void
  @State private var isPopoverPresented = false
  @State private var isHovered = false

  var body: some View {
    Button {
      isPopoverPresented.toggle()
    } label: {
      label
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Capsule())
    }
    .toolbarGlassCapsule(isHighlighted: isHovered && capsule != nil)
    .opacity(capsule == nil ? 0.45 : 1)
    .disabled(capsule == nil)
    .onHover { isHovered = $0 }
    .help(helpText)
    .accessibilityLabel(accessibilityText)
    .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
      if let capsule {
        AgentsPopoverContent(
          capsule: capsule,
          onHandOff: {
            isPopoverPresented = false
            onHandOff()
          }
        )
      }
    }
  }

  /// Mirrors `WorktreeDetailTitleView`'s label metrics (title3 medium,
  /// 20pt icon slot) so the two neighboring pills read as one family.
  @ViewBuilder
  private var label: some View {
    HStack(spacing: 6) {
      if let capsule {
        agentIcon(capsule)
          .frame(width: 20, height: 20)
        Text(capsule.displayName)
      } else {
        Image(systemName: "sparkles")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
          .frame(width: 20, height: 20)
        Text("Agents")
      }
    }
    .font(.title3.weight(.medium))
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
      return "No agent detected in the selected pane"
    }
    return "Agent actions for \(capsule.displayName)"
  }

  private var accessibilityText: String {
    guard let capsule else { return "Agents (no agent detected)" }
    return "Agents: \(capsule.displayName)"
  }
}

/// The agent-actions popover. Each action is one full row — title with a
/// plain-language explanation underneath, highlighted together on hover —
/// so future actions slot in as additional rows.
private struct AgentsPopoverContent: View {
  let capsule: AgentsCapsuleState
  let onHandOff: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      AgentsPopoverRow(
        title: "Hand Off…",
        subtitle: capsule.infoLine,
        systemImage: "arrow.left.arrow.right",
        action: onHandOff
      )
    }
    .padding(6)
    .frame(width: 280, alignment: .leading)
  }
}

private struct AgentsPopoverRow: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: systemImage)
          .frame(width: 16)
          .padding(.top, 2)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isHovered ? Color.accentColor.opacity(0.2) : Color.clear)
    )
    .onHover { isHovered = $0 }
  }
}
