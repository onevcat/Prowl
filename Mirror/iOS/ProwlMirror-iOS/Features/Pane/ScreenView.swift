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
  /// The remote scroll row; a phone on its side drops it while the keyboard is up.
  var showsControls = true
  @State private var position = ScrollPosition(edge: .top)
  /// The end of the output is in view, from the scroll geometry.
  @State private var atBottom = true
  /// The person drags, or the reader still moves from their drag.
  @State private var userScrolls = false
  /// Latest was tapped; scroll again if the reader was still moving and the jump was lost.
  @State private var jumpPending = false
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
      // The composer area is a bar; under it the content fades out instead of showing through.
      .scrollEdgeEffectStyle(.hard, for: .bottom)
      // While following, a taller screen keeps its end in view in the same layout pass.
      .defaultScrollAnchor(session.followsLatest ? .bottom : nil, for: .sizeChanges)
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
      // As in the chat: only the person's scrolling changes following, to whether the end is in
      // view when the reader settles, so a drag down at the end keeps following.
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.visibleRect.maxY - geometry.contentInsets.bottom >= geometry.contentSize.height - 24
      } action: { _, isAtBottom in
        atBottom = isAtBottom
        syncFollowing()
        if isAtBottom { jumpPending = false }
      }
      .onScrollPhaseChange { _, phase in
        switch phase {
        case .tracking, .interacting:
          userScrolls = true
          jumpPending = false
          restoring = nil
        case .decelerating:
          // The first move of a drag can report its geometry before its phase; catch up here.
          syncFollowing()
        case .idle, .animating:
          syncFollowing()
          userScrolls = false
          // A jump made while the reader still decelerated is lost; make it again.
          if phase == .idle, jumpPending, !atBottom {
            withAnimation { position.scrollTo(edge: .bottom) }
          }
        @unknown default:
          userScrolls = false
        }
      }
      .onChange(of: session.revision) { _, _ in
        if session.followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
      }
      .onChange(of: session.completedScroll) { _, completion in
        guard completion != nil else { return }
        restoring = nil
        // The new Host screen opens at its top. A drag that started before it must not settle
        // into following and pull the reader back to the end.
        userScrolls = false
        jumpPending = false
        session.followsLatest = false
        position.scrollTo(edge: .top)
      }
      .safeAreaBar(edge: .top) {
        if showsControls {
          scrollControls
        }
      }
      // An inset, not an overlay: it sits above the pane's composer and key bar.
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if !session.followsLatest {
          Button {
            session.followsLatest = true
            userScrolls = false
            jumpPending = true
            withAnimation { position.scrollTo(edge: .bottom) }
          } label: {
            Image(systemName: "arrow.down").font(.body.weight(.semibold)).padding(4)
          }
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
          .padding(.bottom, 8)
          .disabled(session.isScrolling)
          .accessibilityLabel("Latest")
          .accessibilityIdentifier("mirror-latest")
          .help("Follow the newest output")
          .transition(.scale.combined(with: .opacity))
        }
      }
      .animation(.snappy, value: session.followsLatest)
    }
  }

  /// Remote scrolling moves the Host pane, the only way to read a full-screen app's own history;
  /// a swipe moves only this reader. No bar behind it: the output scrolls under the glass, as in
  /// the chat.
  private var scrollControls: some View {
    HStack(alignment: .center, spacing: 8) {
      Group {
        if session.isScrolling {
          ProgressView("Scrolling…").accessibilityIdentifier("mirror-scroll-progress")
        } else if let error = session.scrollError {
          Text(error)
        } else if session.status == .live && !session.supportsRemoteScroll {
          Text("Update Host to enable remote scrolling.")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      GlassEffectContainer {
        HStack(spacing: 0) {
          remoteScrollButton(.upward)
          Divider().frame(height: 18)
          remoteScrollButton(.downward)
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular.interactive(), in: Capsule())
      }
    }
    .padding(.horizontal)
    .padding(.top, 4)
  }

  /// The person's own scrolling decides following, except while a remote scroll is on its way:
  /// that request already turned following off, and its result shows the new screen's top.
  private func syncFollowing() {
    guard userScrolls, !session.isScrolling else { return }
    session.followsLatest = atBottom
  }

  private func remoteScrollButton(_ direction: MirrorMessage.ScrollDirection) -> some View {
    let upward = direction == .upward
    return Button {
      session.scroll(direction)
    } label: {
      Image(systemName: upward ? "chevron.up" : "chevron.down")
        .font(.body.weight(.semibold))
        .frame(width: 40, height: 36)
        .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .disabled(!session.canScroll(direction))
    .accessibilityLabel(upward ? "Scroll Up" : "Scroll Down")
    .accessibilityIdentifier(upward ? "mirror-scroll-up" : "mirror-scroll-down")
    .help(upward ? "Scroll the Host pane toward earlier output" : "Scroll the Host pane toward later output")
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
