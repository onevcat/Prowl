import SwiftUI

/// Names the agent account the selected pane runs under; tapping opens its
/// settings. Leaves the navigation group's shared background at the call site so
/// it does not merge into the branch title's pill, the same escape
/// `AgentsToolbarButton` uses.
struct AgentAccountToolbarLabel: View {
  let account: String
  let onOpenSettings: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: onOpenSettings) {
      HStack(spacing: 6) {
        Image(systemName: "person.crop.circle")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
          .frame(width: 20, height: 20)
        Text(account)
      }
      .font(.title3.weight(.medium))
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    // Hover feedback must live in the material: a fill under `glassEffect` is
    // swallowed by the compositing.
    .glassEffect(
      isHovered ? .regular.tint(.primary.opacity(0.12)).interactive() : .regular.interactive(),
      in: Capsule()
    )
    .onHover { isHovered = $0 }
    .help("Claude Code and Codex in this pane use the \(account) agent account. Open Agent Accounts settings.")
    .accessibilityLabel("Agent account \(account)")
  }
}
