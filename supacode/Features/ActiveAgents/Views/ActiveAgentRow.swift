import ComposableArchitecture
import SwiftUI

struct ActiveAgentRow: View {
  let entry: ActiveAgentEntry
  let repositoryName: String
  let subtitle: String
  let repositoryColor: RepositoryColorChoice?
  let isDimmed: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 8) {
      agentIcon
      VStack(alignment: .leading, spacing: 2) {
        title
        Text(subtitle)
          .interfaceFont(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 8)
      statusPill
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .contentShape(.rect)
    .opacity(isDimmed ? 0.7 : 1)
  }

  private var title: some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) {
      Text(entry.displayName)
        .interfaceFont(.body, weight: .medium)
        .foregroundStyle(.primary)
      Text("·")
        .interfaceFont(.caption, weight: .semibold)
        .foregroundStyle(.tertiary)
      Text(repositoryName)
        .interfaceFont(.callout, weight: .medium)
        .foregroundStyle(repositoryColor?.color ?? .secondary)
    }
    .lineLimit(1)
  }

  private var agentIcon: some View {
    Group {
      if let icon = entry.iconSource {
        TabIconImage(rawName: icon.storageString, pointSize: 16)
      } else {
        Image(systemName: "sparkle")
      }
    }
    .frame(width: 20, height: 20)
    .accessibilityHidden(true)
  }

  private var statusPill: some View {
    HStack(spacing: 4) {
      if entry.displayState == .working {
        if reduceMotion {
          statusText
        } else {
          BaguaWorkingIndicator()
        }
      } else {
        statusText
      }
    }
    .foregroundStyle(entry.displayState.foregroundStyle)
  }

  private var statusText: some View {
    Text(entry.displayState.label)
      .interfaceFont(.caption2, weight: .semibold)
      .lineLimit(1)
  }
}

/// Bagua trigram spinner: ping-pongs through the eight trigram glyphs as a
/// single `Text`. Deliberately driven by a coarse `.periodic` timeline
/// (~8 fps) that swaps one glyph per tick — far cheaper than redrawing a
/// per-dot grid on the display-linked `.animation` schedule, which rebuilt
/// nine shapes every refresh (60/120 fps) and ran continuously per working
/// agent. With several agents working at once the periodic glyph swap keeps
/// the panel idle between ticks.
struct BaguaWorkingIndicator: View {
  static let frames = ["☰", "☱", "☲", "☳", "☴", "☵", "☶", "☷"]
  static let frameDuration = 0.12

  var body: some View {
    TimelineView(.periodic(from: .now, by: Self.frameDuration)) { context in
      frameText(Self.frame(at: context.date))
    }
  }

  static func frame(at date: Date) -> String {
    frames[frameIndex(at: date)]
  }

  static func frameIndex(at date: Date) -> Int {
    let tick = Int(date.timeIntervalSinceReferenceDate / frameDuration)
    let cycleLength = (frames.count * 2) - 2
    let cycleIndex = ((tick % cycleLength) + cycleLength) % cycleLength
    return cycleIndex < frames.count ? cycleIndex : cycleLength - cycleIndex
  }

  private func frameText(_ frame: String) -> some View {
    Text(frame)
      .font(.system(size: 17, weight: .bold, design: .monospaced))
      .lineLimit(1)
      .frame(width: 20, height: 18)
      .accessibilityHidden(true)
  }
}

extension AgentDisplayState {
  var label: String {
    switch self {
    case .working:
      return "Working"
    case .blocked:
      return "Blocked"
    case .done:
      return "Done"
    case .idle:
      return "Idle"
    }
  }

  var foregroundStyle: Color {
    switch self {
    case .working:
      return .orange
    case .blocked:
      return .red
    case .done:
      return .blue
    case .idle:
      return .secondary
    }
  }
}

#Preview {
  BaguaWorkingIndicator()
    .foregroundStyle(.orange)
    .frame(width: 100, height: 100)
}
