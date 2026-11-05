import SwiftUI

/// A Host's panes grouped by project, each with its agent and what it is doing right now.
struct PanesView: View {
  let host: MirrorHostRecord
  @Binding var path: NavigationPath
  @Environment(MirrorHostSessions.self) private var sessions
  @State private var showsLaunch = false

  private var session: MirrorHostSession { sessions.session(for: host) }

  var body: some View {
    Group {
      if case .failed(let reason) = session.status, session.panes.isEmpty {
        ContentUnavailableView {
          Label("Not Connected", systemImage: "wifi.exclamationmark")
        } description: {
          Text(reason)
        } actions: {
          Button("Retry") { session.retry() }.buttonStyle(.borderedProminent)
        }
      } else if session.panes.isEmpty, session.status == .connecting {
        ProgressView("Connecting to \(host.displayName)…")
      } else if session.panes.isEmpty {
        ContentUnavailableView {
          Label("No Open Panes", systemImage: "rectangle.dashed")
        } description: {
          Text("Open a terminal on the Mac, or start an agent from here.")
        } actions: {
          if session.supportsLaunch {
            Button("New Agent Pane") { showsLaunch = true }.buttonStyle(.borderedProminent)
          }
        }
      } else {
        List {
          if case .failed(let reason) = session.status {
            Section {
              Label(reason, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
              Button("Retry") { session.retry() }
            }
          }
          ForEach(groups, id: \.name) { group in
            Section(group.name) {
              ForEach(group.panes) { pane in
                NavigationLink(value: MirrorPaneRoute(host: host, pane: pane)) { PaneRow(pane: pane) }
                  .accessibilityIdentifier("pane-\(pane.id.uuidString)")
              }
            }
          }
        }
        .refreshable { session.refresh() }
      }
    }
    .navigationTitle(host.displayName)
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("Refresh", systemImage: "arrow.clockwise") { session.refresh() }
          .disabled(session.status != .ready)
          .help("Reload the pane list from the Host")
        Button("New Agent Pane", systemImage: "plus.bubble") { showsLaunch = true }
          .disabled(!session.supportsLaunch || session.status != .ready)
          .accessibilityIdentifier("new-agent-pane")
          .help("Start an Agent Profile in a Host worktree and open it")
      }
    }
    .sheet(isPresented: $showsLaunch) {
      NavigationStack {
        MirrorLaunchView(execute: { try await session.command($0) }) { pane in
          showsLaunch = false
          path.append(MirrorPaneRoute(host: host, pane: pane, launched: true))
        }
        .toolbar { Button("Cancel") { showsLaunch = false } }
      }
    }
    .task {
      if session.status != .ready { session.start() }
    }
  }

  private var groups: [(name: String, panes: [MirrorPaneDescriptor])] {
    let grouped = Dictionary(grouping: session.panes) { $0.projectName ?? String(localized: "Other") }
    return grouped.keys.sorted().map { (name: $0, panes: grouped[$0] ?? []) }
  }
}

struct PaneRow: View {
  let pane: MirrorPaneDescriptor

  var body: some View {
    HStack(spacing: 12) {
      MirrorAgentStateDot(state: pane.agentState, hasAgent: pane.agent != nil)
      VStack(alignment: .leading, spacing: 3) {
        Text(pane.subtitle ?? pane.title).font(.headline).lineLimit(1)
        HStack(spacing: 6) {
          MirrorAgentBadge(agent: pane.agent)
          if pane.busy {
            Text("Mirrored elsewhere").foregroundStyle(.orange)
          }
          Text(pane.directory).lineLimit(1).truncationMode(.head)
        }
        .font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Image(systemName: pane.conversation == .available ? "bubble.left.and.text.bubble.right" : "terminal")
        .foregroundStyle(.secondary)
        .accessibilityLabel(pane.conversation == .available ? "Conversation available" : "Screen only")
    }
    .padding(.vertical, 4)
  }
}

/// The agent's state as one dot: orange while working, red when it waits for a person.
struct MirrorAgentStateDot: View {
  let state: MirrorConversationEvent.AgentState?
  let hasAgent: Bool

  var body: some View {
    ZStack {
      Circle().fill(color).frame(width: 10, height: 10)
      if state == .working {
        Circle().stroke(color.opacity(0.4), lineWidth: 3).frame(width: 14, height: 14)
      }
    }
    .frame(width: 16, height: 16)
    .accessibilityLabel(label)
  }

  private var color: Color {
    guard hasAgent else { return .secondary.opacity(0.4) }
    switch state {
    case .working: return .orange
    case .blocked: return .red
    case .idle: return .green
    case .unknown, nil: return .secondary
    }
  }

  private var label: String {
    guard hasAgent else { return String(localized: "Shell") }
    switch state {
    case .working: return String(localized: "Working")
    case .blocked: return String(localized: "Needs you")
    case .idle: return String(localized: "Idle")
    case .unknown, nil: return String(localized: "Unknown")
    }
  }
}

struct MirrorAgentBadge: View {
  let agent: String?

  var body: some View {
    Text(name)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(.quaternary, in: Capsule())
  }

  private var name: String {
    switch agent {
    case nil: return String(localized: "Shell")
    case "claude": return "Claude Code"
    case "codex": return "Codex"
    case "cursor-agent": return "Cursor"
    case let raw?: return raw.capitalized
    }
  }
}
