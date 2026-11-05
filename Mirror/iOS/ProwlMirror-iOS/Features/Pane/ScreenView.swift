import SwiftUI

/// The row tops and the visible top of the live reader. It is not observable: it changes on every
/// scroll, and no view shows it.
private final class MirrorLiveReadingLayout {
  var rowTops: [MirrorDocument.Row.ID: CGFloat] = [:]
  var visibleTop: CGFloat = 0
}

/// The terminal screen as text (`text-v1`): live output with remote scrolling, or the frozen
/// History pages. Reading positions survive pane switches.
struct ScreenView: View {
  @Bindable var session: MirrorSession
  /// The remote scroll row and the follow row; a phone on its side drops them while the keyboard is up.
  var showsControls = true
  @State private var position = ScrollPosition(edge: .top)
  @State private var layout = MirrorLiveReadingLayout()
  /// The anchor to restore when the live reader appears. While it is set, scrolling does not
  /// replace the stored anchor.
  @State private var restoring: MirrorReadingAnchor?

  init(session: MirrorSession, showsControls: Bool = true) {
    self.session = session
    self.showsControls = showsControls
    _restoring = State(initialValue: session.liveReadingAnchor)
  }

  var body: some View {
    if session.showsHistory {
      MirrorHistoryView(session: session)
    } else {
      liveReader
    }
  }

  private var liveReader: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let error = session.error {
            Text(error).font(.caption).foregroundStyle(.secondary)
          }
          MirrorDocumentView(text: session.text, onRowTop: rowTopChanged)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("mirror-live-text")
          Color.clear.frame(height: 1).id("latest")
        }
        .padding()
        .coordinateSpace(MirrorDocumentView.rowSpace)
      }
      .scrollPosition($position)
      .accessibilityIdentifier("mirror-live-scroll")
      .onDisappear { restoring = session.liveReadingAnchor }
      .onAppear {
        if session.followsLatest {
          restoring = nil
          position.scrollTo(edge: .bottom)
        } else if let restoring {
          restore(restoring, with: proxy)
        }
      }
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        max(0, geometry.contentOffset.y + geometry.contentInsets.top)
      } action: { _, top in
        layout.visibleTop = top
        storeAnchor()
      }
      .onScrollPhaseChange { _, phase in
        guard phase == .interacting else { return }
        session.followsLatest = false
        restoring = nil
      }
      .onChange(of: session.revision) { _, _ in
        if session.followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
      }
      .onChange(of: session.completedScroll) { _, completion in
        guard completion != nil else { return }
        restoring = nil
        position.scrollTo(edge: .top)
      }
      .safeAreaInset(edge: .top) {
        if showsControls {
          scrollControls
        }
      }
      .safeAreaInset(edge: .bottom) {
        if showsControls {
          followControls(proxy)
        }
      }
    }
  }

  private var scrollControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button("Scroll Up", systemImage: "arrow.up") { session.scroll(.upward) }
          .disabled(!session.canScroll(.upward))
          .accessibilityIdentifier("mirror-scroll-up")
          .help("Scroll the Host pane toward earlier output")
        Spacer()
        if session.isScrolling {
          ProgressView("Scrolling…").accessibilityIdentifier("mirror-scroll-progress")
        }
        Spacer()
        Button("Scroll Down", systemImage: "arrow.down") { session.scroll(.downward) }
          .disabled(!session.canScroll(.downward))
          .accessibilityIdentifier("mirror-scroll-down")
          .help("Scroll the Host pane toward later output")
      }
      if let error = session.scrollError {
        Text(error).foregroundStyle(.secondary)
      } else if session.status == .live && !session.supportsRemoteScroll {
        Text("Update Host to enable remote scrolling.").foregroundStyle(.secondary)
      }
    }
    .font(.caption).padding(.horizontal).padding(.vertical, 8).background(.bar)
  }

  private func followControls(_ proxy: ScrollViewProxy) -> some View {
    HStack {
      Toggle("Follow latest", isOn: $session.followsLatest).toggleStyle(.button)
      Spacer()
      Button("Latest") {
        session.followsLatest = true
        proxy.scrollTo("latest", anchor: .bottom)
      }
    }
    .disabled(session.isScrolling)
    .font(.caption).padding(.horizontal).padding(.vertical, 8).background(.bar)
  }

  private func restore(_ anchor: MirrorReadingAnchor, with proxy: ScrollViewProxy) {
    if let top = layout.rowTops[anchor.row] {
      restoring = nil
      position.scrollTo(y: top + anchor.offset)
    } else if MirrorDocument(session.text).rows.contains(where: { $0.id == anchor.row }) {
      // Lay out the anchor row first. `rowTopChanged` then applies the offset in the row.
      proxy.scrollTo(anchor.row, anchor: .top)
    } else {
      restoring = nil
      position.scrollTo(edge: .bottom)
    }
  }

  private func rowTopChanged(_ row: MirrorDocument.Row.ID, _ top: CGFloat?) {
    layout.rowTops[row] = top
    guard let top else { return }
    if let anchor = restoring {
      guard anchor.row == row else { return }
      restoring = nil
      position.scrollTo(y: top + anchor.offset)
    } else {
      storeAnchor()
    }
  }

  private func storeAnchor() {
    guard restoring == nil,
      let anchor = MirrorReadingAnchor(top: layout.visibleTop, rowTops: layout.rowTops)
    else { return }
    session.liveReadingAnchor = anchor
  }
}

struct MirrorHistoryView: View {
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
          VStack(alignment: .leading) {
            Button("Load Earlier 200 Lines") { session.loadHistory() }
              .disabled(
                session.historyOffset == 0 || session.isLoadingHistory || session.status != .live)
            // iOS 27 sends no taps to a button in the same stack as selectable text rows.
            LazyVStack(alignment: .leading) {
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
