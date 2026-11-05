import SwiftUI

/// The home screen (docs-ai 089): the agents of one Host, grouped like the Mac sidebar. A state
/// summary on top counts what is blocked, working and done, and filters the list to one state.
struct AgentsView: View {
  let host: MirrorHostRecord
  @Bindable var store: MirrorHostStore
  @Binding var path: NavigationPath
  let onAddHost: () -> Void
  let onManageHosts: () -> Void
  @Environment(MirrorHostSessions.self) private var sessions
  @State private var stateFilter: MirrorPaneState?
  @State private var expandedTerminals: Set<String> = []
  @State private var launchRequest: LaunchRequest?

  private var session: MirrorHostSession { sessions.session(for: host) }

  struct LaunchRequest: Identifiable {
    let project: String?
    var id: String { project ?? "" }
  }

  var body: some View {
    let all = MirrorAgentsRoster(panes: session.panes)
    let roster = stateFilter == nil ? all : MirrorAgentsRoster(panes: session.panes, state: stateFilter)
    List {
      if case .failed(let reason) = session.status {
        Section {
          MirrorConnectionBanner(reason: reason) { session.retry() }
        }
      }
      if !all.counts.isEmpty {
        Section {
          MirrorStateSummary(counts: all.counts, selection: $stateFilter)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
      }
      ForEach(roster.projects) { project in
        Section {
          ForEach(project.agents) { pane in
            row(pane)
          }
          if !project.terminals.isEmpty {
            TerminalsRow(
              count: project.terminals.count, expanded: expandedTerminals.contains(project.name)
            ) { toggleTerminals(project.name) }
            if expandedTerminals.contains(project.name) {
              ForEach(project.terminals) { pane in row(pane) }
            }
          }
        } header: {
          ProjectHeader(
            project: project, canLaunch: session.supportsLaunch && session.status == .ready
          ) { launchRequest = .init(project: project.name) }
        }
      }
    }
    .listStyle(.insetGrouped)
    .overlay { if session.panes.isEmpty { emptyState } }
    .refreshable { session.refresh() }
    .animation(.snappy, value: stateFilter)
    .navigationTitle(host.displayName)
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        HostMenu(
          current: host, hosts: store.hosts, status: session.status,
          select: { store.select($0.id) }, onAddHost: onAddHost, onManageHosts: onManageHosts)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("New Session", systemImage: "plus") { launchRequest = .init(project: nil) }
          .disabled(!session.supportsLaunch || session.status != .ready)
          .accessibilityIdentifier("new-agent-pane")
          .help("Start an Agent Profile in a Host project and open it")
      }
    }
    .sheet(item: $launchRequest) { request in
      NavigationStack {
        MirrorLaunchView(execute: { try await session.command($0) }, project: request.project) { pane in
          launchRequest = nil
          path.append(MirrorPaneRoute(host: host, pane: pane, launched: true))
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark") { launchRequest = nil }
          }
        }
      }
    }
    .task(id: host.id) {
      if session.status != .ready { session.start() }
    }
    .onChange(of: session.hostName) { _, name in store.updateHostName(host.id, name: name) }
    .task(id: reconnectKey) {
      // A Host that went away (restart, sleep, network change) is tried again while the list is
      // on screen, so the person does not have to find Retry.
      guard case .failed = session.status else { return }
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled, case .failed = session.status else { return }
      session.retry()
    }
    .onChange(of: all.counts) { _, counts in
      if let stateFilter, counts[stateFilter, default: 0] == 0 { self.stateFilter = nil }
    }
  }

  /// Changes on each failure so the reconnect task restarts.
  private var reconnectKey: String {
    if case .failed(let reason) = session.status { return "failed:\(reason)" }
    return "ok"
  }

  private func row(_ pane: MirrorPaneDescriptor) -> some View {
    NavigationLink(value: MirrorPaneRoute(host: host, pane: pane)) {
      MirrorPaneRow(pane: pane)
    }
    .accessibilityIdentifier("pane-\(pane.id.uuidString)")
  }

  @ViewBuilder private var emptyState: some View {
    switch session.status {
    case .connecting, .idle:
      ProgressView("Connecting to \(host.displayName)…")
    case .failed:
      EmptyView()
    case .ready:
      ContentUnavailableView {
        Label("No Open Panes", systemImage: "rectangle.dashed")
      } description: {
        Text("Open a terminal on the Mac, or start an agent from here.")
      } actions: {
        if session.supportsLaunch {
          Button("New Session", systemImage: "plus") { launchRequest = .init(project: nil) }
            .buttonStyle(.glassProminent)
        }
      }
    }
  }

  private func toggleTerminals(_ name: String) {
    withAnimation(.snappy) {
      if expandedTerminals.contains(name) { expandedTerminals.remove(name) } else { expandedTerminals.insert(name) }
    }
  }
}
