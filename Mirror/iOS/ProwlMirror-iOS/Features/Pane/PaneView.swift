import SwiftUI

/// One Host pane (docs-ai 089 S2): the agent's conversation when the Host can serve it, the
/// terminal screen otherwise. The title carries the pane's state; one toolbar button switches
/// Chat and Terminal; a floating composer sits underneath.
struct PaneView: View {
  private let host: MirrorHostRecord?
  private let pane: MirrorPaneDescriptor
  private let opensOnAppear: Bool
  private let launched: Bool
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
    launched = route.launched
    _session = State(initialValue: session)
  }

  /// A session that is already connected, for fixtures and tests.
  init(session: MirrorSession, pane: MirrorPaneDescriptor, host: MirrorHostRecord?) {
    self.host = host
    self.pane = pane
    opensOnAppear = false
    launched = false
    _session = State(initialValue: session)
  }

  /// The roster keeps refreshing behind this screen; it knows first when an agent appears.
  private var rosterPane: MirrorPaneDescriptor? {
    host.flatMap { sessions.existing(for: $0)?.panes.first { $0.id == pane.id } }
  }

  private var support: MirrorPaneDescriptor.ConversationSupport? {
    rosterPane?.conversation ?? session.pane?.conversation ?? pane.conversation
  }

  private var shown: MirrorPaneDescriptor { session.pane ?? pane }
  private var chatAvailable: Bool { session.supportsConversation && support != .unsupported }
  /// The live status from the conversation when there is one; the roster's "done" otherwise.
  private var state: MirrorPaneState {
    if session.agentState != nil, shown.agent != nil {
      return MirrorPaneState(agentState: session.agentState, hasAgent: true)
    }
    return MirrorPaneState(rosterPane ?? shown)
  }

  private var compactWhileComposing: Bool { isComposing && verticalSizeClass == .compact }

  var body: some View {
    Group {
      switch session.mode {
      case .conversation: ConversationView(session: session)
      case .screen: ScreenView(session: session, showsControls: !compactWhileComposing)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .top, spacing: 0) {
      if let problem = connectionProblem {
        MirrorPaneConnectionBanner(problem: problem, session: session)
          .padding(.horizontal).padding(.top, 4)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 8) {
        if session.status == .live, session.supportsPromptRespond,
          // Only Chat keeps the prompt current; Terminal shows the menu itself.
          session.mode == .conversation, let prompt = session.conversation.openScreenPrompt,
          !(prompt.choices ?? []).isEmpty
        {
          MirrorPromptPanel(prompt: prompt, answer: session.promptAnswer) { choice in
            session.answerPrompt(prompt.id, choice: choice)
          }
          .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if state == .blocked, session.status == .live {
          MirrorBlockedStrip(kind: session.conversation.status?.kind)
        }
        if session.mode == .screen, session.canSendKeys, !compactWhileComposing {
          MirrorKeyBar(session: session)
        }
        ComposerBar(session: session, isEditing: $isComposing)
      }
      .animation(.snappy, value: session.conversation.openScreenPrompt?.id)
      .padding(.horizontal, 12)
      .padding(.bottom, 6)
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle(shown.displayTitle)
    .toolbar {
      ToolbarItem(placement: .principal) {
        if !compactWhileComposing {
          PaneTitle(title: shown.displayTitle, state: state, location: location, status: session.status)
        }
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        if chatAvailable || session.mode == .conversation {
          Button {
            userChoseMode = true
            session.switchMode(session.mode == .conversation ? .screen : .conversation)
          } label: {
            Label(
              session.mode == .conversation ? "Terminal" : "Chat",
              systemImage: session.mode == .conversation ? "apple.terminal" : "text.bubble")
          }
          .accessibilityIdentifier("pane-mode")
          .help(session.mode == .conversation ? "Show the terminal screen" : "Show the agent's conversation")
        }
        menu
      }
    }
    .task {
      guard opensOnAppear, session.pane == nil else { return }
      if launched { session.expectAgent(of: pane) }
      session.open(pane, mode: pane.conversation == .available ? .conversation : .screen)
    }
    .onDisappear { if opensOnAppear { session.disconnect() } }
    .onChange(of: rosterPane) { _, current in
      if let current { session.refreshDescriptor(current) }
    }
    .onChange(of: support) { _, new in
      // A Shell pane that starts an agent moves to the conversation unless the person chose the screen.
      if new == .available, session.mode == .screen, session.supportsConversation, !userChoseMode {
        session.switchMode(.conversation)
      }
    }
  }

  private var location: String {
    [shown.projectName, shown.worktreeName].compactMap { $0 }.joined(separator: " / ")
  }

  private var connectionProblem: MirrorPaneConnectionBanner.Problem? {
    switch session.status {
    case .live, .connecting, .subscribing, .choosingPane: nil
    case .takenOver: .takenOver
    case .disconnected, .hostStopped, .paneClosed, .incompatible: .lost(session.status.label)
    }
  }

  private var menu: some View {
    Menu {
      if session.mode == .screen {
        Button(session.showsHistory ? "Live Output" : "History", systemImage: "clock.arrow.circlepath") {
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
      Label("Pane actions", systemImage: "ellipsis")
    }
    .accessibilityIdentifier("pane-actions")
    .help("History, reconnect and disconnect")
  }
}

/// The navigation title: the pane's name, and under it its state and where it runs.
private struct PaneTitle: View {
  let title: String
  let state: MirrorPaneState
  let location: String
  let status: MirrorSession.Status

  var body: some View {
    VStack(spacing: 1) {
      Text(title).font(.headline).lineLimit(1)
      HStack(spacing: 5) {
        if status == .connecting || status == .subscribing {
          ProgressView().controlSize(.mini)
          Text(status.label).foregroundStyle(.secondary)
        } else {
          MirrorStateLabel(state: state, showsQuiet: true)
          if !location.isEmpty {
            Text("·").foregroundStyle(.tertiary)
            Text(location).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
      .font(.caption)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("pane-title")
  }
}

/// A lost or taken-over connection: the reason in red and the way back.
struct MirrorPaneConnectionBanner: View {
  enum Problem: Equatable {
    case lost(String)
    case takenOver
  }

  let problem: Problem
  @Bindable var session: MirrorSession

  var body: some View {
    HStack(spacing: 10) {
      switch problem {
      case .lost(let reason):
        MirrorFailureLabel(text: reason)
        Spacer(minLength: 8)
        Button("Reconnect") { session.retry() }
          .font(.subheadline.weight(.semibold))
          .help("Connect to the pane again")
      case .takenOver:
        MirrorFailureLabel(text: String(localized: "Mirrored on another device"))
        Spacer(minLength: 8)
        Button("Take Over") { session.retry(takeover: true) }
          .font(.subheadline.weight(.semibold))
          .help("Mirror this pane here and end the other mirror")
      }
    }
    .font(.subheadline)
    .padding(.horizontal, 14).padding(.vertical, 10)
    .glassEffect(.regular, in: Capsule())
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("pane-connection-banner")
  }
}

/// The agent waits for a person: what kind of answer it needs. The answer itself is on the Mac
/// until the Host supports answering from here (docs-ai 089 S4).
struct MirrorBlockedStrip: View {
  let kind: String?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
      Text(text).font(.subheadline).lineLimit(2)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("pane-blocked")
  }

  private var text: String {
    switch kind {
    case "permission": String(localized: "Blocked · Waiting for a permission decision on the Mac")
    case "question": String(localized: "Blocked · Waiting for your answer on the Mac")
    case "auth": String(localized: "Blocked · Waiting for sign-in on the Mac")
    default: String(localized: "Blocked · Waiting for you on the Mac")
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
