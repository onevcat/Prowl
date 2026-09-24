import SwiftUI

/// Per-state agent counts for the notched compact bar, in attention order. States with no agents
/// are omitted so the narrow wing only spends width on what exists.
struct AgentIslandStateSummary: Equatable {
  struct Item: Equatable, Identifiable {
    let state: AgentDisplayState
    let count: Int
    var id: AgentDisplayState { state }
  }

  static let order: [AgentDisplayState] = [.blocked, .done, .working, .idle]

  let items: [Item]

  init(entries: [ActiveAgentEntry]) {
    var counts: [AgentDisplayState: Int] = [:]
    for entry in entries {
      counts[entry.displayState, default: 0] += 1
    }
    items = Self.order.compactMap { state in
      guard let count = counts[state], count > 0 else { return nil }
      return Item(state: state, count: count)
    }
  }

  /// "2 blocked, 1 working" for VoiceOver, since the glyphs carry no text of their own.
  var accessibilityLabel: String {
    items.map { "\($0.count) \($0.state.label.lowercased())" }.joined(separator: ", ")
  }
}

extension AgentDisplayState {
  /// Follows the Shelf spine markers (bolt, exclamation, check); the island also counts Idle,
  /// which the Shelf deliberately leaves unmarked.
  var islandSymbolName: String {
    switch self {
    case .working:
      return "bolt.fill"
    case .blocked:
      return "exclamationmark.circle.fill"
    case .done:
      return "checkmark.circle.fill"
    case .idle:
      return "moon.zzz.fill"
    }
  }
}

struct AgentIslandStateSummaryView: View {
  /// `compact` fits the narrow notch wing; `regular` is the floating pill's roomier variant.
  enum Size {
    case compact
    case regular
  }

  let summary: AgentIslandStateSummary
  let size: Size

  var body: some View {
    Group {
      switch size {
      case .compact:
        // The notch wing is only as wide as the icon cluster. Tighten the spacing first, then
        // drop the Idle count, which needs no attention; the roster still lists those agents.
        ViewThatFits(in: .horizontal) {
          itemRow(summary.items, spacing: 6)
          itemRow(summary.items, spacing: 3)
          itemRow(summary.items.filter { $0.state != .idle }, spacing: 3)
        }
      case .regular:
        itemRow(summary.items, spacing: 10)
      }
    }
    .lineLimit(1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(summary.accessibilityLabel)
  }

  private func itemRow(_ items: [AgentIslandStateSummary.Item], spacing: CGFloat) -> some View {
    HStack(spacing: spacing) {
      ForEach(items) { item in
        HStack(spacing: size == .compact ? 2 : 3) {
          Image(systemName: item.state.islandSymbolName)
            .font(size == .compact ? .caption2.weight(.bold) : .caption.weight(.bold))
            .accessibilityHidden(true)
          Text("\(item.count)")
            .font(size == .compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
            .monospacedDigit()
        }
        .foregroundStyle(item.state.foregroundStyle)
      }
    }
  }
}
