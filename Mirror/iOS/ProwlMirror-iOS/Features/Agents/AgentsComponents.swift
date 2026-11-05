import SwiftUI

/// The Host switcher in the toolbar: a Mac glyph that carries the connection state.
struct HostMenu: View {
  let current: MirrorHostRecord
  let hosts: [MirrorHostRecord]
  let status: MirrorHostSession.Status
  let select: (MirrorHostRecord) -> Void
  let onAddHost: () -> Void
  let onManageHosts: () -> Void

  var body: some View {
    Menu {
      Section(status.label) {
        ForEach(hosts) { host in
          Button {
            select(host)
          } label: {
            if host.id == current.id {
              Label(host.displayName, systemImage: "checkmark")
            } else {
              Text(host.displayName)
            }
            Text(host.endpoint)
          }
        }
      }
      Button("Add Host…", systemImage: "plus", action: onAddHost)
      Button("Manage Hosts", systemImage: "list.bullet", action: onManageHosts)
    } label: {
      Image(systemName: "macbook")
        .overlay(alignment: .bottomTrailing) { connectionMark.offset(x: 4, y: 3) }
    }
    .accessibilityIdentifier("host-menu")
    .accessibilityLabel("\(current.displayName), \(status.label)")
    .help("Switch the Host or manage paired Hosts")
  }

  @ViewBuilder private var connectionMark: some View {
    switch status {
    case .ready:
      Circle().fill(.green).frame(width: 7, height: 7)
    case .connecting, .idle:
      Circle().fill(.secondary).frame(width: 7, height: 7)
    case .failed:
      Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(.white, .red)
    }
  }
}

/// A Host that cannot be reached: the reason and a way to try again. The last roster stays.
struct MirrorConnectionBanner: View {
  let reason: String
  let retry: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      MirrorFailureLabel(text: reason).font(.subheadline)
      Spacer(minLength: 8)
      Button("Retry", action: retry)
        .font(.subheadline.weight(.semibold))
        .help("Connect to the Host again")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("host-connection-banner")
  }
}

/// Blocked, working and done agents as three counts, the way the Mac's Active Agents panel
/// ranks them. A count filters the list to its state; tap it again to show everything.
struct MirrorStateSummary: View {
  let counts: [MirrorPaneState: Int]
  @Binding var selection: MirrorPaneState?

  private static let states: [MirrorPaneState] = [.blocked, .working, .done]

  var body: some View {
    HStack(spacing: 10) {
      ForEach(Self.states, id: \.self) { state in
        let count = counts[state, default: 0]
        let selected = selection == state
        Button {
          selection = selected ? nil : state
        } label: {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
              glyph(state)
              Spacer(minLength: 0)
              Text(count, format: .number)
                .font(.title2.weight(.semibold).monospacedDigit())
                // Explicit colors: a borderless button tints `.primary` with the accent.
                .foregroundStyle(count == 0 ? Color(.tertiaryLabel) : Color.primary)
                .contentTransition(.numericText())
            }
            Text(state.label).font(.footnote.weight(.medium)).foregroundStyle(Color.secondary)
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            selected ? AnyShapeStyle(state.color.opacity(0.14)) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .strokeBorder(selected ? state.color.opacity(0.5) : .clear, lineWidth: 1)
          )
          .contentShape(.rect(cornerRadius: 14))
        }
        // Borderless keeps each button its own tap target inside one list row.
        .buttonStyle(.borderless)
        .disabled(count == 0 && !selected)
        .accessibilityLabel("\(count) \(state.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("state-summary-\(state.identifier)")
        .help(selected ? "Show all agents" : "Show only the \(state.label.lowercased()) agents")
      }
    }
    .sensoryFeedback(.selection, trigger: selection)
    // A list row with several buttons would otherwise read as one element.
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private func glyph(_ state: MirrorPaneState) -> some View {
    switch state {
    case .working:
      MirrorBaguaIndicator().foregroundStyle(state.color)
    case .blocked:
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(state.color).font(.subheadline)
    default:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(state.color).font(.subheadline)
    }
  }
}

extension MirrorPaneState {
  var identifier: String {
    switch self {
    case .blocked: "blocked"
    case .working: "working"
    case .done: "done"
    case .idle: "idle"
    case .unknown: "unknown"
    case .terminal: "terminal"
    }
  }
}

/// A project section title: the repository color, the sidebar name and its group.
struct ProjectHeader: View {
  let project: MirrorAgentsRoster.Project
  let canLaunch: Bool
  let launch: () -> Void

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(MirrorRepositoryColor.color(project.color) ?? .secondary)
        .frame(width: 8, height: 8)
      Text(project.name).lineLimit(1)
      if let group = project.group, group != project.name {
        Text(group).foregroundStyle(.tertiary).lineLimit(1)
      }
      Spacer()
      if canLaunch {
        Menu {
          Button("New Session in \(project.name)", systemImage: "plus", action: launch)
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 28, height: 22)
            .contentShape(.rect)
        }
        .accessibilityLabel("\(project.name) actions")
        .help("Actions for \(project.name)")
      }
    }
    .font(.subheadline.weight(.semibold))
  }
}

struct TerminalsRow: View {
  let count: Int
  let expanded: Bool
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 12) {
        Image(systemName: "apple.terminal").foregroundStyle(.secondary).frame(width: 24)
        Text("^[\(count) terminal](inflect: true)").foregroundStyle(.secondary)
        Spacer()
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
          .rotationEffect(.degrees(expanded ? 90 : 0))
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("terminals-toggle")
    .help(expanded ? "Hide the terminals of this project" : "Show the terminals of this project")
  }
}

/// One pane: the agent's mark, the tab title, the worktree and how long ago its state
/// changed, and the state the way the Mac shows it.
struct MirrorPaneRow: View {
  let pane: MirrorPaneDescriptor

  var body: some View {
    let state = MirrorPaneState(pane)
    HStack(spacing: 12) {
      MirrorAgentIcon(agent: pane.agent)
        .foregroundStyle(state == .terminal ? .secondary : .primary)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(pane.displayTitle).lineLimit(1)
        HStack(spacing: 4) {
          Text(pane.worktreeName ?? URL(fileURLWithPath: pane.directory).lastPathComponent).lineLimit(1)
          if pane.busy {
            Text("·")
            Text("Mirrored elsewhere").foregroundStyle(.orange)
          } else if let date = pane.stateChangedDate, state != .terminal {
            Text("·")
            MirrorRelativeTime(date: date)
          }
        }
        .font(.footnote).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      MirrorStateLabel(state: state)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
}

/// Repository colors as the Mac encodes them for the roster: a preset name or `#RRGGBB`.
nonisolated enum MirrorRepositoryColor {
  static func color(_ value: String?) -> Color? {
    switch value {
    case nil: nil
    case "red": .red
    case "orange": .orange
    case "yellow": .yellow
    case "green": .green
    case "mint": .mint
    case "cyan": .cyan
    case "blue": .blue
    case "purple": .purple
    case "pink": .pink
    case "gray": .gray
    case let hex?:
      hexColor(hex)
    }
  }

  private static func hexColor(_ hex: String) -> Color? {
    guard hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return Color(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}

/// "2m ago" that keeps itself current while the list stays on screen.
struct MirrorRelativeTime: View {
  let date: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 20)) { context in
      Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
        .id(context.date)
    }
  }
}
