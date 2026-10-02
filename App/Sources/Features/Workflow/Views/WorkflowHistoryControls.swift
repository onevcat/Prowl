import SwiftUI

extension WorkflowHistoryStatus {
  static func tint(_ state: String) -> Color {
    switch state {
    case "completed": .green
    case "active", "running": .blue
    case "needs_attention", "interrupted", "iteration_limit_reached": .orange
    case "failed": .red
    default: .secondary
    }
  }
}

struct WorkflowHistoryStatusIcon: View {
  let state: String

  var body: some View {
    Image(systemName: WorkflowHistoryStatus.symbol(state))
      .foregroundStyle(WorkflowHistoryStatus.tint(state))
      .accessibilityLabel(WorkflowHistoryStatus.label(state))
      .help(WorkflowHistoryStatus.label(state))
  }
}

struct WorkflowHistoryIconButton: View {
  let label: String
  let symbol: String
  let action: () -> Void

  var body: some View {
    Button(label, systemImage: symbol, action: action)
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help(label)
      .accessibilityLabel(label)
  }
}

struct WorkflowHistoryDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        configuration.isExpanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 10)
            .accessibilityHidden(true)
          configuration.label
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .contentShape(.rect)
      }
      .buttonStyle(WorkflowHistoryRowButtonStyle(expanded: configuration.isExpanded))
      .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
      .accessibilityHint("Expand or collapse step details")
      .help(configuration.isExpanded ? "Collapse step" : "Expand step")
      if configuration.isExpanded {
        configuration.content
          .padding(.leading, 26)
          .padding(.trailing, 8)
          .padding(.vertical, 10)
      }
    }
  }
}

private struct WorkflowHistoryRowButtonStyle: ButtonStyle {
  let expanded: Bool

  func makeBody(configuration: Configuration) -> some View {
    Row(configuration: configuration, expanded: expanded)
  }

  private struct Row: View {
    let configuration: ButtonStyleConfiguration
    let expanded: Bool
    @State private var hovering = false

    var body: some View {
      configuration.label
        .background(
          Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.08 : expanded ? 0.04 : 0),
          in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { hovering = $0 }
    }
  }
}
