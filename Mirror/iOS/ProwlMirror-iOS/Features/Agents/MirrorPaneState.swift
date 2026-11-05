import SwiftUI

/// What a pane is doing, in the words and colors of Prowl for Mac (docs-ai 089): working is
/// orange with the Bagua spinner, blocked is red, done (idle and not looked at yet) is blue,
/// idle is quiet. A pane without an agent is a terminal.
nonisolated enum MirrorPaneState: Hashable, Sendable {
  case blocked
  case working
  case done
  case idle
  case unknown
  case terminal

  init(_ pane: MirrorPaneDescriptor) {
    guard pane.agent != nil else {
      self = .terminal
      return
    }
    switch pane.displayState {
    case .blocked?: self = .blocked
    case .working?: self = .working
    case .done?: self = .done
    case .idle?: self = .idle
    case nil:
      switch pane.agentState {
      case .working?: self = .working
      case .blocked?: self = .blocked
      case .idle?: self = .idle
      case .unknown?, nil: self = .unknown
      }
    }
  }

  init(agentState: MirrorConversationEvent.AgentState?, hasAgent: Bool) {
    guard hasAgent else {
      self = .terminal
      return
    }
    switch agentState {
    case .working?: self = .working
    case .blocked?: self = .blocked
    case .idle?: self = .idle
    case .unknown?, nil: self = .unknown
    }
  }

  /// The order of the Agents screen: what needs the person first.
  var priority: Int {
    switch self {
    case .blocked: 0
    case .working: 1
    case .done: 2
    case .idle: 3
    case .unknown: 4
    case .terminal: 5
    }
  }

  var needsAttention: Bool { self == .blocked || self == .done }
}

extension MirrorPaneState {
  var color: Color {
    switch self {
    case .working: .orange
    case .blocked: .red
    case .done: .blue
    case .idle, .unknown, .terminal: .secondary
    }
  }

  var label: String {
    switch self {
    case .working: String(localized: "Working")
    case .blocked: String(localized: "Blocked")
    case .done: String(localized: "Done")
    case .idle: String(localized: "Idle")
    case .unknown: String(localized: "Unknown")
    case .terminal: String(localized: "Terminal")
    }
  }
}

/// The state as Prowl for Mac shows it: the Bagua spinner while working, a dot and a word
/// otherwise. Idle and terminal panes stay quiet unless `showsQuiet` is set.
struct MirrorStateLabel: View {
  let state: MirrorPaneState
  var showsQuiet = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 5) {
      switch state {
      case .working:
        if reduceMotion {
          Circle().fill(state.color).frame(width: 7, height: 7)
        } else {
          MirrorBaguaIndicator().foregroundStyle(state.color)
        }
        Text(state.label)
      case .blocked, .done:
        Circle().fill(state.color).frame(width: 7, height: 7)
        Text(state.label)
      case .idle, .unknown, .terminal:
        if showsQuiet {
          Circle().fill(.tertiary).frame(width: 7, height: 7)
          Text(state.label)
        }
      }
    }
    .font(.footnote.weight(.medium))
    .foregroundStyle(state.color)
    .accessibilityElement(children: .combine)
  }
}

/// Bagua trigram spinner, as in Prowl for Mac (`BaguaWorkingIndicator`): one `Text` that steps
/// through the eight trigrams on a coarse timeline, which costs far less than a per-frame
/// animation when several agents work at once.
struct MirrorBaguaIndicator: View {
  nonisolated static let frames = ["☰", "☱", "☲", "☳", "☴", "☵", "☶", "☷"]
  nonisolated static let frameDuration = 0.12
  @ScaledMetric(relativeTo: .footnote) private var size = 14

  var body: some View {
    TimelineView(.periodic(from: .now, by: Self.frameDuration)) { context in
      Text(Self.frames[Self.frameIndex(at: context.date)])
        .font(.system(size: size, weight: .bold, design: .monospaced))
        .lineLimit(1)
        .accessibilityHidden(true)
    }
  }

  nonisolated static func frameIndex(at date: Date) -> Int {
    let tick = Int(date.timeIntervalSinceReferenceDate / frameDuration)
    let cycleLength = (frames.count * 2) - 2
    let cycleIndex = ((tick % cycleLength) + cycleLength) % cycleLength
    return cycleIndex < frames.count ? cycleIndex : cycleLength - cycleIndex
  }
}

/// A failure or a lost connection: stronger than any state dot.
struct MirrorFailureLabel: View {
  let text: String

  var body: some View {
    Label {
      Text(text)
    } icon: {
      Image(systemName: "exclamationmark.circle.fill").symbolRenderingMode(.multicolor)
    }
    .foregroundStyle(.red)
  }
}

/// The agent's brand mark from the Mac's icon set, tinted like text; a sparkle when the
/// agent has no mark, a terminal for a shell.
struct MirrorAgentIcon: View {
  let agent: String?
  @ScaledMetric(relativeTo: .body) private var size = 18

  var body: some View {
    Group {
      if let name = Self.assetName(for: agent) {
        Image(name).resizable().scaledToFit()
      } else {
        Image(systemName: agent == nil ? "apple.terminal" : "sparkle").resizable().scaledToFit()
      }
    }
    .frame(width: size, height: size)
    // Rows combine their children; the mark adds which agent runs there.
    .accessibilityLabel(Self.displayName(for: agent))
  }

  /// `agent` is the Host's `DetectedAgent` raw value; the names match `CommandIconMap` on Mac.
  nonisolated static func assetName(for agent: String?) -> String? {
    switch agent {
    case "amp": "Amp"
    case "antigravity": "Antigravity"
    case "claude": "ClaudeCode"
    case "cline": "Cline"
    case "codex": "Codex"
    case "copilot": "GitHubCopilot"
    case "cursor-agent": "Cursor"
    case "devin": "Devin"
    case "droid": "Droid"
    case "gemini": "Gemini"
    case "kimi": "Kimi"
    case "opencode": "OpenCode"
    case "qwen": "Qwen"
    case "grok": "Grok"
    case "omp": "OMP"
    case "pi": "Pi"
    case "trae": "Trae"
    default: nil
    }
  }

  nonisolated static func displayName(for agent: String?) -> String {
    switch agent {
    case nil: String(localized: "Terminal")
    case "claude": "Claude Code"
    case "codex": "Codex"
    case "cursor-agent": "Cursor"
    case "copilot": "GitHub Copilot"
    case "opencode": "OpenCode"
    case "qodercli": "Qoder"
    case "omp": "Oh My Pi"
    case let raw?: raw.capitalized
    }
  }
}
