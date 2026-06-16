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

  @ViewBuilder
  private var title: some View {
    if let conversationTitle = Self.conversationTitle(for: entry) {
      Text(conversationTitle)
        .font(.body.weight(.medium))
        .foregroundStyle(.primary)
        .lineLimit(1)
    } else {
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
  }

  static func primaryTitle(for entry: ActiveAgentEntry, repositoryName: String) -> String {
    guard let title = conversationTitle(for: entry) else {
      return "\(entry.displayName) · \(repositoryName)"
    }
    return title
  }

  private static func conversationTitle(for entry: ActiveAgentEntry) -> String? {
    let title = entry.conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let title, !title.isEmpty else { return nil }
    return title
  }

  private var agentIcon: some View {
    Group {
      if let icon = entry.iconSource {
        TabIconImage(rawName: icon.storageString, pointSize: 16)
      } else {
        Image(systemName: "sparkle")
      }
    }
    .foregroundStyle(agentIconTint)
    .frame(width: 20, height: 20)
    .accessibilityHidden(true)
  }

  private var agentIconTint: Color {
    AgentIconTint.color(for: entry.agent) ?? .primary
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
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
  }
}

enum AgentIconTint {
  static func color(for agent: DetectedAgent) -> Color? {
    guard let components = components(for: agent) else { return nil }
    return Color(
      red: Double(components.red) / 255,
      green: Double(components.green) / 255,
      blue: Double(components.blue) / 255
    )
  }

  static func colorHex(for agent: DetectedAgent) -> String? {
    components(for: agent).map { "#\(String(format: "%02X%02X%02X", $0.red, $0.green, $0.blue))" }
  }

  private static func components(for agent: DetectedAgent) -> (red: UInt8, green: UInt8, blue: UInt8)? {
    switch agent {
    case .claude:
      // Simple Icons Claude Code, source: https://code.claude.com
      return (0xD9, 0x77, 0x57)
    case .codex:
      // Sampled from the Codex icon supplied in CleanShot 2026-06-15 at 01.38.31@2x.png.
      return (0x63, 0x70, 0xF2)
    case .gemini:
      // Simple Icons Google Gemini, source: https://gemini.google.com
      return (0x8E, 0x75, 0xB2)
    case .amp:
      // Simple Icons AMP, source: https://amp.dev
      return (0x00, 0x5A, 0xF0)
    case .cline:
      // Simple Icons Cline, source: https://cline.bot/assets/branding/logos/cline-wordmark-black.svg
      return (0x18, 0x18, 0x1B)
    case .cursor, .opencode, .copilot, .pi:
      return (0x00, 0x00, 0x00)
    case .kimi:
      // Sampled from https://www.kimi.com/favicon.ico.
      return (0x10, 0x80, 0xF8)
    case .droid:
      return nil
    }
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
