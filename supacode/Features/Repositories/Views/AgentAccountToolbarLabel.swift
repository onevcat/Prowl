import SwiftUI

/// Names the agent account the selected pane runs under; tapping opens its
/// settings.
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
      .toolbarCapsuleLabel()
    }
    .toolbarGlassCapsule(isHighlighted: isHovered)
    .onHover { isHovered = $0 }
    .help("Claude Code and Codex in this pane use the \(account) agent account. Open Agent Accounts settings.")
    .accessibilityLabel("Agent account \(account)")
  }
}
