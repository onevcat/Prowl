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
        subtitleLine
          .font(.caption)
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
        .font(.body.weight(.medium))
        .foregroundStyle(.primary)
      Text("·")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
      Text(repositoryName)
        .font(.callout.weight(.medium))
        .foregroundStyle(repositoryColor?.color ?? .secondary)
    }
    .lineLimit(1)
  }

  /// A remote agent shows its host before the usual subtitle (docs-ai 082, L0 item 10). One
  /// text truncates as a unit, so the subtitle goes first.
  @ViewBuilder
  private var subtitleLine: some View {
    if let remote = entry.remote {
      HStack(spacing: 3) {
        Image(systemName: "network")
          .imageScale(.small)
          .accessibilityHidden(true)
        Text(verbatim: "\(RemoteAgentPresentation.hostLabel(for: remote)) \u{00B7} \(subtitle)")
      }
    } else {
      Text(subtitle)
    }
  }

  /// The connection health of a remote agent the host does not confirm, under its state.
  @ViewBuilder
  private var healthText: some View {
    if let remote = entry.remote {
      switch RemoteAgentHealth(remote) {
      case .live, .unknownState:
        // An unknown state is the pill's "Unknown": the connection itself is healthy.
        EmptyView()
      case .lastSeen(let date):
        Text("Last seen \(date, style: .relative) ago")
      case .unavailable:
        Text("Status unavailable")
      }
    }
  }

  /// A remote state the host does not confirm, or that no evidence decides, is shown but not
  /// emphasized.
  private var isStateUnconfirmed: Bool {
    guard let remote = entry.remote else { return false }
    return RemoteAgentHealth(remote) != .live
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
    VStack(alignment: .trailing, spacing: 1) {
      HStack(spacing: 4) {
        if entry.displayState == .working, !reduceMotion, !isStateUnconfirmed {
          BaguaWorkingIndicator()
        } else {
          statusText
        }
      }
      .foregroundStyle(isStateUnconfirmed ? Color.secondary : entry.displayState.foregroundStyle)
      healthText
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .fixedSize()
  }

  private var statusText: some View {
    Text(entry.remote?.isStateKnown == false ? String(localized: "Unknown") : entry.displayState.label)
      .font(.caption2.weight(.semibold))
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
  // "Done" and "Blocked" have other meanings elsewhere in the app, so the states use their own keys.
  var label: String {
    switch self {
    case .working:
      return String(localized: "agentState.working", defaultValue: "Working")
    case .blocked:
      return String(localized: "agentState.blocked", defaultValue: "Blocked")
    case .done:
      return String(localized: "agentState.done", defaultValue: "Done")
    case .idle:
      return String(localized: "agentState.idle", defaultValue: "Idle")
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
