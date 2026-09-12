import Network
import SwiftUI

struct ContentView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var sessions: [MirrorSession] = []
  @State private var selectedID: UUID?
  @State private var showsConnection = false
  @State private var columns: NavigationSplitViewVisibility =
    UIDevice.current.userInterfaceIdiom == .phone ? .detailOnly : .all
  @State private var compactColumn: NavigationSplitViewColumn =
    UIDevice.current.userInterfaceIdiom == .phone ? .detail : .sidebar
  @State private var wasBackgrounded = false

  init() {
    #if DEBUG
      if CommandLine.arguments.contains("--mirror-ui-fixture") {
        let multiple = CommandLine.arguments.contains("--mirror-ui-multiple-fixtures")
        let fixture = MirrorUIFixture.session(longOutput: multiple)
        let fixtures =
          multiple
          ? [fixture, MirrorUIFixture.session(name: "Second Fixture")] : [fixture]
        _sessions = State(initialValue: fixtures)
        _selectedID = State(initialValue: fixture.id)
      }
    #endif
  }

  #if DEBUG
    @State private var fixtureCreatedPane: MirrorPaneDescriptor?
  #endif

  var body: some View {
    #if DEBUG
      if CommandLine.arguments.contains("--mirror-ui-launch-fixture") {
        NavigationStack {
          if let pane = fixtureCreatedPane {
            Text("Created mirror: \(pane.title)").accessibilityIdentifier("created-mirror")
          } else {
            MirrorLaunchView(execute: MirrorUIFixture.launchCommand) { fixtureCreatedPane = $0 }
          }
        }
      } else {
        sessionContent
      }
    #else
      sessionContent
    #endif
  }

  private var sessionContent: some View {
    NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
      List(selection: $selectedID) {
        ForEach(sessions) { session in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(
                session.pane?.projectName ?? session.pane?.title ?? session.configuration.address
              )
              .font(.headline)
              Text(session.pane?.subtitle ?? session.configuration.address).font(.caption)
              Text(session.status.label).font(.caption).foregroundStyle(session.status.displayColor)
            }
            Spacer(minLength: 8)
            Button {
              close(session)
            } label: {
              Image(systemName: "xmark.circle")
                .padding(8).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
              "Close mirror \(session.pane?.projectName ?? session.configuration.address)"
            )
            .accessibilityIdentifier(
              "close-mirror-\(session.pane?.projectName ?? session.configuration.address)"
            )
            .help("Remove this mirror; the Host terminal keeps running")
          }
          .tag(session.id)
          .contextMenu {
            Button("Close Mirror", role: .destructive) {
              close(session)
            }
          }
        }
      }
      .navigationTitle("Prowl Mirror")
      .toolbar {
        Button("Add Remote Pane", systemImage: "plus") { showsConnection = true }
          .accessibilityIdentifier("add-remote-pane")
      }
      .overlay {
        if sessions.isEmpty {
          ContentUnavailableView(
            "Connect to Prowl", systemImage: "network",
            description: Text("Add a Host, then choose an open pane."))
        }
      }
    } detail: {
      if let session = sessions.first(where: { $0.id == selectedID }) {
        MirrorReadingView(session: session)
          .id(session.id)
      } else {
        ContentUnavailableView {
          Label("Choose a Remote Pane", systemImage: "rectangle.split.2x1")
        } description: {
          Text("Your Host keeps running the terminal. This device mirrors its current text.")
        } actions: {
          Button("Add Remote Pane") { showsConnection = true }.buttonStyle(.borderedProminent)
        }
      }
    }
    .onChange(of: selectedID) { _, new in
      if new != nil { compactColumn = .detail }
    }
    .sheet(isPresented: $showsConnection) {
      AddConnectionView { session in
        sessions.append(session)
        selectedID = session.id
        showsConnection = false
      }
    }
    .onChange(of: scenePhase) { _, new in
      if new == .background { wasBackgrounded = true }
      if new == .active, wasBackgrounded {
        wasBackgrounded = false
        for session in sessions { session.foreground() }
      }
    }
  }

  private func close(_ session: MirrorSession) {
    session.disconnect()
    sessions.removeAll { $0.id == session.id }
    if selectedID == session.id { selectedID = sessions.first?.id }
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

private struct AddConnectionView: View {
  @Environment(\.dismiss) private var dismiss
  let onSelect: (MirrorSession) -> Void
  @State private var address = ""
  @State private var port = "7880"
  @State private var key = ""
  @State private var error: String?
  @State private var session: MirrorSession?
  @State private var added = false

  var body: some View {
    NavigationStack {
      Form {
        if let session, session.status == .choosingPane {
          if session.supportsLaunch {
            Section {
              NavigationLink {
                MirrorLaunchView(session: session) { pane in
                  session.select(pane)
                  added = true
                  onSelect(session)
                }
              } label: {
                Label("New Agent Pane", systemImage: "plus.rectangle")
              }
              .accessibilityIdentifier("new-agent-pane")
            }
          }
          Section("Select a Host pane") {
            if session.panes.isEmpty {
              Text("No open panes. Open a terminal on Host, then refresh.")
            }
            ForEach(session.panes) { pane in
              Button {
                session.select(pane)
                added = true
                onSelect(session)
              } label: {
                HStack {
                  VStack(alignment: .leading) {
                    Text(pane.projectName ?? pane.title).font(.headline)
                    Text(pane.subtitle ?? pane.directory).font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer()
                  Text(pane.busy ? "Take Over" : "Mirror")
                }
              }
            }
            Button("Refresh Panes") { session.refreshPanes() }
          }
        } else {
          Section("Host connection") {
            TextField("Host IP", text: $address)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
              .accessibilityIdentifier("host-address")
            TextField("Port", text: $port).keyboardType(.numberPad)
            MirrorPairingCodeField(key: $key)
            Button(session?.status == .connecting ? "Connecting…" : "Connect") { connect() }
              .disabled(session?.status == .connecting)
          }
        }
        if let error = error ?? session?.error {
          Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
      }
      .navigationTitle("Remote Mirror Pane")
      .toolbar { Button("Cancel") { dismiss() } }
      .onAppear {
        #if DEBUG
          if CommandLine.arguments.contains("--mirror-ui-connection-fixture") {
            if session == nil {
              let fixture = MirrorUIFixture.connectionSession()
              session = fixture
              fixture.connect()
            }
            return
          }
        #endif
        do {
          if let saved = try MirrorSavedConnection.load() {
            address = saved.address
            port = String(saved.port)
            key = saved.pairingKey
          }
        } catch { self.error = error.localizedDescription }
      }
    }
    .onDisappear { if !added { session?.disconnect() } }
  }

  private func connect() {
    let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let number = UInt16(port), number > 0,
      IPv4Address(host) != nil || IPv6Address(host) != nil
    else {
      error = "Enter an IP address and a port between 1 and 65535."
      return
    }
    error = nil
    session?.disconnect()
    let config = MirrorSavedConnection(
      address: host, port: number,
      pairingKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
    let newSession = MirrorSession(configuration: config)
    newSession.onVerifiedConnection = { verified in
      do { try verified.save() } catch { self.error = error.localizedDescription }
    }
    session = newSession
    newSession.connect()
  }
}

private struct MirrorReadingView: View {
  @Bindable var session: MirrorSession
  @State private var showsConnectionEditor = false
  @State private var position: ScrollPosition
  @State private var observedInitialPosition = false
  @State private var isEditing = false

  init(session: MirrorSession) {
    self.session = session
    _position = State(initialValue: ScrollPosition(y: session.liveReadingOffset))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(
          session.status.label,
          systemImage: session.status == .live ? "checkmark.circle" : "network.slash"
        )
        .foregroundStyle(session.status.displayColor)
        .fontWeight(session.status == .live ? .regular : .semibold)
        Spacer()
        if session.status == .takenOver {
          Button("Take Over") { session.retry(takeover: true) }
        } else if session.status == .disconnected || session.status == .hostStopped {
          Button("Retry") { session.retry() }
        }
      }
      .font(.callout).padding()
      if let error = session.error {
        Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
      }
      if session.status == .choosingPane {
        List(session.panes) { pane in
          Button {
            session.select(pane)
          } label: {
            VStack(alignment: .leading) {
              Text(pane.projectName ?? pane.title)
              Text(pane.subtitle ?? pane.directory).font(.caption)
              Text(pane.busy ? "Take Over" : "Mirror")
            }
          }
        }
        Button("Refresh Panes") { session.refreshPanes() }
      }
      if session.showsHistory {
        MirrorHistoryView(session: session)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              MirrorDocumentView(text: session.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("mirror-live-text")
              Color.clear.frame(height: 1).id("latest")
            }
            .padding()
          }
          .scrollPosition($position)
          .accessibilityIdentifier("mirror-live-scroll")
          .onDisappear { observedInitialPosition = false }
          .onAppear {
            if session.followsLatest {
              position.scrollTo(edge: .bottom)
            } else {
              position.scrollTo(y: session.liveReadingOffset)
            }
          }
          .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentOffset.y + geometry.contentInsets.top)
          } action: { _, offset in
            if observedInitialPosition { session.liveReadingOffset = offset }
            observedInitialPosition = true
          }
          .onScrollPhaseChange { _, phase in
            if phase == .interacting { session.followsLatest = false }
          }
          .onChange(of: session.revision) { _, _ in
            if session.followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
          }
          .safeAreaInset(edge: .bottom) {
            HStack {
              Toggle("Follow latest", isOn: $session.followsLatest).toggleStyle(.button)
              Spacer()
              Button("Latest") {
                session.followsLatest = true
                proxy.scrollTo("latest", anchor: .bottom)
              }
            }
            .font(.caption).padding(.horizontal).padding(.vertical, 8).background(.bar)
          }
        }
      }
      Divider()
      VStack(alignment: .leading) {
        MirrorComposer(session: session, isEditing: $isEditing)
          .fixedSize(horizontal: false, vertical: true)
          .overlay(alignment: .topLeading) {
            if session.draft.isEmpty {
              Text("Write a message").foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
            }
          }
          .accessibilityLabel("Write a message")
          .accessibilityIdentifier("mirror-message-input")
        HStack {
          Text(session.submissionHint)
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          if isEditing {
            Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") {
              isEditing = false
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("mirror-dismiss-keyboard")
          }
          if session.submission?.outcome.status == .unknown
            || session.submission?.outcome.status == .pending
          {
            Button("Check Receipt") { session.querySubmission() }
              .disabled(session.status != .live)
          }
          if session.submission?.outcome.status == .unknown {
            Button("I've Checked Host Output") { session.acknowledgeUnknownSubmission() }
          }
          Button("Send", systemImage: "arrow.up") { session.submitDraft() }
            .disabled(!session.canSubmit)
        }
        if let submission = session.submission,
          submission.outcome.status == .pending || submission.outcome.status == .unknown
        {
          DisclosureGroup("Submitted message") {
            ScrollView { Text(submission.text).textSelection(.enabled) }
              .frame(maxHeight: 120)
          }
          .font(.caption)
        }
      }
      .padding()
    }
    .navigationTitle(session.pane?.title ?? "Remote Mirror")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      Button(session.showsHistory ? "Live Output" : "History", systemImage: "clock") {
        if session.showsHistory {
          session.showsHistory = false
        } else {
          session.loadHistory(refresh: true)
        }
      }
      .disabled(!session.showsHistory && (!session.supportsHistory || session.status != .live))
      Button("Edit Connection", systemImage: "network") { showsConnectionEditor = true }
        .help("Update the Host address, port or pairing key")
    }
    .sheet(isPresented: $showsConnectionEditor) {
      MirrorConnectionEditor(configuration: session.configuration) { configuration in
        session.updateConnection(configuration)
      }
    }
  }
}

private struct MirrorConnectionEditor: View {
  @Environment(\.dismiss) private var dismiss
  let configuration: MirrorSavedConnection
  let onConnect: (MirrorSavedConnection) -> Void
  @State private var address = ""
  @State private var port = ""
  @State private var key = ""
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        TextField("Host IP", text: $address)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        TextField("Port", text: $port).keyboardType(.numberPad)
        MirrorPairingCodeField(key: $key)
        Text("Reconnect only if the pane is free. Changing Host opens pane selection.")
          .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).foregroundStyle(.red) }
        Button("Reconnect") {
          let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
          guard let number = UInt16(port), number > 0,
            IPv4Address(host) != nil || IPv6Address(host) != nil
          else {
            error = "Enter a valid IP address and port."
            return
          }
          let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
          do { if !secret.isEmpty { _ = try MirrorPairingCode.normalized(secret) } } catch {
            self.error = error.localizedDescription
            return
          }
          onConnect(
            .init(
              address: host, port: number, pairingKey: secret,
              credential: secret.isEmpty ? configuration.credential : nil))
          dismiss()
        }
      }
      .navigationTitle("Edit Connection")
      .toolbar { Button("Cancel") { dismiss() } }
      .onAppear {
        address = configuration.address
        port = String(configuration.port)
        key = configuration.pairingKey
      }
    }
  }
}

private struct MirrorHistoryView: View {
  @Bindable var session: MirrorSession
  @State private var position: ScrollPosition
  @State private var observedInitialPosition = false

  init(session: MirrorSession) {
    self.session = session
    _position = State(initialValue: ScrollPosition(y: session.historyReadingOffset))
  }
  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        if let capturedAt = session.historyCapturedAt {
          Text("Captured \(capturedAt.formatted(date: .omitted, time: .standard))")
        }
        Spacer()
        Button("Refresh History") { session.loadHistory(refresh: true) }
          .disabled(session.isLoadingHistory || session.status != .live)
      }.font(.caption)
      if session.historyTruncated {
        Text("Older lines omitted. The first retained line may begin mid-paragraph.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text(
        "Loaded lines \(session.historyOffset + 1)–\(session.historyOffset + session.historyLines.count)"
      )
      .font(.caption).foregroundStyle(.secondary)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading) {
            Button("Load Earlier 200 Lines") { session.loadHistory() }
              .disabled(
                session.historyOffset == 0 || session.isLoadingHistory || session.status != .live)
            ForEach(
              session.historyOffset..<(session.historyOffset + session.historyLines.count),
              id: \.self
            ) { index in
              let line = session.historyLines[index - session.historyOffset]
              Text(line.isEmpty ? " " : line).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(index)
            }
          }
        }
        .scrollPosition($position)
        .accessibilityIdentifier("mirror-history-scroll")
        .onAppear { position.scrollTo(y: session.historyReadingOffset) }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
          max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, offset in
          if observedInitialPosition { session.historyReadingOffset = offset }
          observedInitialPosition = true
        }
        .onChange(of: session.historyCapturedAt) { _, _ in
          position.scrollTo(y: session.historyReadingOffset)
        }
        .onChange(of: session.historyOffset) { old, new in
          if old > new { proxy.scrollTo(old, anchor: .top) }
        }
      }
      if session.isLoadingHistory { ProgressView("Loading history…") }
    }.padding()
  }
}
