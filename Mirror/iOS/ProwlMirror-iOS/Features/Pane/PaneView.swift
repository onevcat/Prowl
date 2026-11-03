import SwiftUI

/// One Host pane: the agent's conversation when the Host can serve it, the terminal screen
/// otherwise, with one composer underneath (docs-ai 088).
struct PaneView: View {
  private let host: MirrorHostRecord?
  private let pane: MirrorPaneDescriptor
  private let opensOnAppear: Bool
  @State private var session: MirrorSession
  @State private var userChoseMode = false
  @State private var isComposing = false
  @Environment(MirrorHostSessions.self) private var sessions
  @Environment(\.verticalSizeClass) private var verticalSizeClass

  /// A pane reached from the roster; `session` is a fresh, unopened connection to its Host.
  init(route: MirrorPaneRoute, session: MirrorSession) {
    host = route.host
    pane = route.pane
    opensOnAppear = true
    _session = State(initialValue: session)
  }

  /// A session that is already connected, for fixtures and tests.
  init(session: MirrorSession, pane: MirrorPaneDescriptor, host: MirrorHostRecord?) {
    self.host = host
    self.pane = pane
    opensOnAppear = false
    _session = State(initialValue: session)
  }

  /// The roster keeps refreshing behind this screen; it knows first when an agent appears.
  private var support: MirrorPaneDescriptor.ConversationSupport? {
    let roster = host.flatMap { sessions.existing(for: $0)?.panes.first { $0.id == pane.id } }
    return roster?.conversation ?? session.pane?.conversation ?? pane.conversation
  }

  private var chatAvailable: Bool { session.supportsConversation && support != .unsupported }

  var body: some View {
    VStack(spacing: 0) {
      // A phone on its side has no room for the header above the keyboard.
      if !(isComposing && verticalSizeClass == .compact) {
        PaneHeader(session: session, mode: modeBinding, chatAvailable: chatAvailable)
        Divider()
      }
      Group {
        switch session.mode {
        case .conversation: ConversationView(session: session)
        case .screen: ScreenView(session: session, showsControls: !(isComposing && verticalSizeClass == .compact))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      ComposerBar(session: session, isEditing: $isComposing)
    }
    .navigationTitle(pane.subtitle ?? pane.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          if session.mode == .screen {
            Button(session.showsHistory ? "Live Output" : "History", systemImage: "clock") {
              if session.showsHistory {
                session.showsHistory = false
              } else {
                session.loadHistory(refresh: true)
              }
            }
            .disabled(!session.showsHistory && (!session.supportsHistory || session.status != .live))
          }
          if session.status == .takenOver {
            Button("Take Over", systemImage: "hand.raised") { session.retry(takeover: true) }
          } else if session.status != .live && session.status != .connecting && session.status != .subscribing {
            Button("Reconnect", systemImage: "arrow.clockwise") { session.retry() }
          }
          Divider()
          Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { session.disconnect() }
        } label: {
          Image(systemName: "ellipsis.circle").accessibilityLabel("Pane actions")
        }
        .accessibilityIdentifier("pane-actions")
      }
    }
    .task {
      guard opensOnAppear, session.pane == nil else { return }
      session.open(pane, mode: pane.conversation == .available ? .conversation : .screen)
    }
    .onDisappear { if opensOnAppear { session.disconnect() } }
    .onChange(of: support) { _, new in
      // A Shell pane that starts an agent moves to the conversation unless the person chose the screen.
      if new == .available, session.mode == .screen, session.supportsConversation, !userChoseMode {
        session.switchMode(.conversation)
      }
    }
  }

  private var modeBinding: Binding<MirrorSession.Mode> {
    Binding(
      get: { session.mode },
      set: { newMode in
        userChoseMode = true
        session.switchMode(newMode)
      })
  }
}

/// Connection and agent state on the left, the representation picker on the right.
private struct PaneHeader: View {
  @Bindable var session: MirrorSession
  @Binding var mode: MirrorSession.Mode
  let chatAvailable: Bool

  var body: some View {
    HStack(spacing: 12) {
      statusPill
      Spacer(minLength: 8)
      Picker("View", selection: $mode) {
        Text("Chat").tag(MirrorSession.Mode.conversation)
        Text("Screen").tag(MirrorSession.Mode.screen)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 180)
      .disabled(!chatAvailable && mode == .screen)
      .accessibilityIdentifier("pane-mode")
      .help("Show the agent's conversation or the terminal screen")
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }

  @ViewBuilder private var statusPill: some View {
    switch session.status {
    case .live:
      switch session.agentState {
      case .working:
        Label {
          Text("Working")
        } icon: {
          ProgressView().controlSize(.mini)
        }
        .foregroundStyle(.orange)
      case .blocked:
        Label("Needs you", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
      case .idle:
        Label("Idle", systemImage: "checkmark.circle").foregroundStyle(.green)
      case .unknown, nil:
        Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
      }
    case .connecting, .subscribing:
      Label {
        Text(session.status.label)
      } icon: {
        ProgressView().controlSize(.mini)
      }
      .foregroundStyle(.secondary)
    case .takenOver:
      Button("Taken over · Take Over", systemImage: "hand.raised") { session.retry(takeover: true) }
        .foregroundStyle(.red)
    case .disconnected, .hostStopped, .paneClosed, .incompatible, .choosingPane:
      Button(session.status.label, systemImage: "arrow.clockwise") { session.retry() }
        .foregroundStyle(.red)
    }
  }
}

extension MirrorSession.Status {
  var displayColor: Color {
    switch self {
    case .live: .green
    case .disconnected, .takenOver, .hostStopped, .paneClosed, .incompatible: .red
    case .connecting, .choosingPane, .subscribing: .secondary
    }
  }
}
