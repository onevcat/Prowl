import SwiftUI

/// The chat (docs-ai 089 S2): the person's messages in bubbles, the agent's words as text, and
/// each run of tool calls folded into one quiet row between them.
struct ConversationView: View {
  @Bindable var session: MirrorSession
  /// A phone on its side has no reader left above the composer while the keyboard is up: Latest
  /// would sit under the navigation bar, so it waits until the keyboard is down.
  var showsLatest = true
  /// The chat keeps its end in view as content arrives. Only the person's own scrolling changes
  /// it, to whether the end is in view when they let go; content that grows (a snapshot that
  /// arrives late, rows that size themselves) never turns it off.
  @State private var follows = true
  /// The end of the chat is in view, from the scroll geometry.
  @State private var atBottom = true
  /// The person drags, or the scroll view still moves from their drag.
  @State private var userScrolls = false
  /// Latest was tapped; scroll again if the view was still moving and the jump was lost.
  @State private var jumpPending = false
  @State private var position = ScrollPosition(edge: .bottom)
  @State private var expandedSteps: Set<UInt64> = []
  @State private var detail: ToolDetail?
  /// Rows are laid out eagerly so the bottom anchor never lands on an unsized lazy row;
  /// older rows load in pages on request instead.
  @State private var visibleLimit = ConversationView.page

  private static let page = 120
  /// About 80 characters of body text; the composer uses it too, so both line up.
  static let readableWidth: CGFloat = 720
  private var store: MirrorConversationStore { session.conversation }

  var body: some View {
    let (rows, hiddenCount) = MirrorChatRow.page(store.items, limit: visibleLimit)
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if store.gap {
          caption("Earlier messages are not available on this device.")
        }
        if hiddenCount > 0 {
          Button("Show \(min(hiddenCount, Self.page)) earlier") { visibleLimit += Self.page }
            .buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
            .accessibilityIdentifier("conversation-earlier")
        }
        if store.isEmpty, session.status == .live {
          ContentUnavailableView(
            "Nothing here yet", systemImage: "text.bubble",
            description: Text("Messages appear as you and the agent write them."))
        }
        ForEach(rows) { row in
          ChatRowView(
            row: row, expanded: binding(for: row.id), showDetail: { detail = $0 }
          )
          .id(row.id)
        }
        if session.agentState == .working {
          HStack(spacing: 6) {
            MirrorBaguaIndicator()
            Text("Working")
          }
          .font(.footnote.weight(.medium))
          .foregroundStyle(.orange)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("conversation-working")
        }
        Color.clear.frame(height: 1).id("conversation-bottom")
      }
      // A readable column on a wide screen; the scroll view stays full width, so a drag in the
      // margins still scrolls.
      .frame(maxWidth: Self.readableWidth, alignment: .leading)
      .padding(.horizontal)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity)
    }
    .scrollPosition($position)
    // The composer is the only thing in the bar: a soft fade under it leaves the chat its height,
    // with no band behind the floating field.
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .defaultScrollAnchor(.bottom)
    // While following, growth keeps the end in view in the same layout pass: the snapshot, later
    // batches and new messages land without a visible scroll. Otherwise what is read stays put.
    .defaultScrollAnchor(follows ? .bottom : nil, for: .sizeChanges)
    .scrollDismissesKeyboard(.interactively)
    .accessibilityIdentifier("conversation-scroll")
    .onScrollGeometryChange(for: Bool.self) { geometry in
      // The visible rect spans the whole scroll view; the end shows above the composer area.
      geometry.visibleRect.maxY - geometry.contentInsets.bottom >= geometry.contentSize.height - 40
    } action: { _, isAtBottom in
      atBottom = isAtBottom
      // A drag down at the end (a bounce) stays at the end, so it keeps following.
      if userScrolls { follows = isAtBottom }
      if isAtBottom { jumpPending = false }
    }
    // Content or the composer area (a note, the keyboard) changed height: catch up with the end
    // when the anchor alone did not.
    .onScrollGeometryChange(for: CGFloat.self) { geometry in
      geometry.contentSize.height + geometry.contentInsets.bottom
    } action: { _, _ in
      if follows, !userScrolls, !atBottom { position.scrollTo(edge: .bottom) }
    }
    .onScrollPhaseChange { _, phase in
      switch phase {
      case .tracking, .interacting:
        userScrolls = true
        jumpPending = false
      case .decelerating:
        // The first move of a drag can report its geometry before its phase; catch up here.
        if userScrolls { follows = atBottom }
      case .idle, .animating:
        if userScrolls { follows = atBottom }
        userScrolls = false
        // A jump made while the view still decelerated is lost; make it again.
        if phase == .idle, jumpPending, !atBottom {
          withAnimation { position.scrollTo(edge: .bottom) }
        }
      @unknown default:
        userScrolls = false
      }
    }
    // An inset, not an overlay: it sits above the pane's floating composer, at its trailing edge,
    // in one row with the pane's Hide Keyboard.
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if showsLatest, !follows {
        Button {
          follows = true
          userScrolls = false
          jumpPending = true
          withAnimation { position.scrollTo(edge: .bottom) }
        } label: {
          MirrorFloatingIcon(systemName: "arrow.down")
        }
        .mirrorFloatingButton()
        .accessibilityLabel("Latest")
        .accessibilityIdentifier("conversation-latest")
        .help("Scroll to the newest message")
        .mirrorFloatingRow(.trailing, maxWidth: Self.readableWidth + 8)
      }
    }
    .animation(.snappy, value: follows)
    .sheet(item: $detail) { detail in
      ToolDetailView(detail: detail, session: session)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
  }

  private func caption(_ text: LocalizedStringKey) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
  }

  private func binding(for id: UInt64) -> Binding<Bool> {
    Binding(
      get: { expandedSteps.contains(id) },
      set: { expanded in
        if expanded { expandedSteps.insert(id) } else { expandedSteps.remove(id) }
      })
  }
}

/// A tool call opened from a steps row: its identity only, so the sheet reads the call's
/// current state and shows the output once it arrives.
struct ToolDetail: Identifiable {
  let id: UInt64
}

private struct ChatRowView: View {
  let row: MirrorChatRow
  @Binding var expanded: Bool
  let showDetail: (ToolDetail) -> Void

  var body: some View {
    switch row {
    case .steps(let steps):
      StepsRow(steps: steps, expanded: $expanded, showDetail: showDetail)
    case .item(let item):
      ConversationItemView(item: item)
    }
  }
}

struct ConversationItemView: View {
  let item: MirrorConversationItem

  var body: some View {
    switch item {
    case .user(_, let text, let origin, let images, let at):
      UserBubble(text: text, origin: origin, images: images, at: at)
    case .queued(_, let text):
      HStack(spacing: 6) {
        Image(systemName: "clock")
        Text(MirrorInjectedText.split(text).message).lineLimit(2)
      }
      .font(.callout).foregroundStyle(.secondary)
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .frame(maxWidth: .infinity, alignment: .trailing)
      .accessibilityLabel("Queued: \(MirrorInjectedText.split(text).message)")
    case .assistant(_, let text, _, _):
      AssistantText(text: text)
    case .reasoning(_, _, let summary?) where !summary.text.isEmpty:
      ThoughtText(text: summary)
    case .reasoning, .tool, .attention:
      // Folded into steps rows or shown above the composer.
      EmptyView()
    case .prompt(_, let prompt, let resolved?, _):
      PromptCard(prompt: prompt, resolved: resolved)
    case .prompt(_, _, nil, _):
      // An open prompt shows once, above the composer (docs-ai 089 S4).
      EmptyView()
    case .session(_, let kind, let session, _):
      SessionDivider(kind: kind, session: session)
    case .compaction:
      SessionDivider(text: String(localized: "Context compacted"))
    case .subagent(_, let kind, let agent):
      Label(
        kind == .subagentStarted
          ? String(localized: "\(agent.type ?? String(localized: "Subagent")) started")
          : String(localized: "\(agent.type ?? String(localized: "Subagent")) finished"),
        systemImage: "person.2"
      )
      .font(.caption).foregroundStyle(.secondary)
    case .notice(_, let notice, _):
      Label(notice.text, systemImage: notice.level == .warning ? "exclamationmark.triangle" : "info.circle")
        .font(.caption).foregroundStyle(notice.level == .warning ? .orange : .secondary)
    }
  }
}

private struct UserBubble: View {
  let text: MirrorBoundedText
  let origin: MirrorConversationEvent.MessageOrigin?
  let images: Int?
  let at: Date?
  @State private var showsInjected = false
  @State private var showsAll = false

  /// Long prompts (briefs, pasted logs) fold so they do not fill several screens.
  private static let foldedLines = 12

  var body: some View {
    let parts = MirrorInjectedText.split(text.text)
    let isLong = parts.message.count > 700 || parts.message.split(separator: "\n").count > Self.foldedLines
    VStack(alignment: .trailing, spacing: 4) {
      VStack(alignment: .leading, spacing: 6) {
        if let images, images > 0 {
          Label("^[\(images) image](inflect: true)", systemImage: "photo").font(.caption).opacity(0.85)
        }
        Text(parts.message)
          .lineLimit(isLong && !showsAll ? Self.foldedLines : nil)
          .textSelection(.enabled)
        if isLong {
          Button(showsAll ? "Show less" : "Show more") {
            withAnimation(.snappy) { showsAll.toggle() }
          }
          .buttonStyle(.plain)
          .font(.caption.weight(.semibold))
          .opacity(0.85)
          .accessibilityIdentifier("conversation-user-more")
          .help(showsAll ? "Fold the message" : "Show the whole message")
        }
        if text.truncated, parts.injected == nil { Text("…").opacity(0.7) }
        if let injected = parts.injected {
          Button {
            withAnimation(.snappy) { showsInjected.toggle() }
          } label: {
            Label("Prowl instructions", systemImage: showsInjected ? "chevron.down" : "chevron.right")
              .font(.caption)
          }
          .buttonStyle(.plain)
          .opacity(0.8)
          .accessibilityIdentifier("conversation-injected-toggle")
          .help("Show the instructions Prowl added to this message")
          if showsInjected {
            Text(text.truncated ? injected + "…" : injected).font(.caption).opacity(0.8).textSelection(.enabled)
          }
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      .foregroundStyle(.white)
      .background(Color("UserBubble"), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      HStack(spacing: 4) {
        if let origin, origin != .human { Text(originLabel(origin)) }
        if let at { Text(at, style: .time) }
      }
      .font(.caption2).foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.leading, 48)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversation-user")
  }

  private func originLabel(_ origin: MirrorConversationEvent.MessageOrigin) -> String {
    switch origin {
    case .human: ""
    case .queued: String(localized: "queued")
    case .automation: String(localized: "automation")
    case .system: String(localized: "system")
    case .other: String(localized: "other")
    }
  }
}

private struct AssistantText: View {
  let text: MirrorBoundedText

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      MirrorMarkdownView(text: text.text)
      if text.truncated {
        Text("Message truncated by the Host.").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversation-assistant")
  }
}

/// What the agent thinks between steps, when it shows that text (Claude Code's visible
/// thinking, Codex's reasoning summary): like a reply, in secondary type.
private struct ThoughtText: View {
  let text: MirrorBoundedText

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      MirrorMarkdownView(text: text.text)
        .font(.callout)
        .foregroundStyle(.secondary)
      if text.truncated {
        Text("Thought truncated by the Host.").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversation-thought")
  }
}

/// A run of tool calls as one line in secondary type: what kinds ran, how many, how many
/// failed, or what runs now. Expanded, one line per call; a line opens its details.
private struct StepsRow: View {
  let steps: MirrorChatRow.Steps
  @Binding var expanded: Bool
  let showDetail: (ToolDetail) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.snappy) { expanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          HStack(spacing: -3) {
            ForEach(Array(steps.kinds.prefix(3).enumerated()), id: \.offset) { _, kind in
              Image(systemName: MirrorToolKindStyle.symbol(kind))
                .font(.caption2.weight(.semibold))
                .frame(width: 18, height: 18)
                .background(Color(.tertiarySystemFill), in: Circle())
            }
          }
          summary
          Spacer(minLength: 4)
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .foregroundStyle(.secondary)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("conversation-steps")
      .help(expanded ? "Hide the tool calls" : "Show the tool calls")
      if expanded {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(steps.tools, id: \.id) { item in
            if case .tool(let id, let start, let end, _, _) = item {
              StepLine(start: start, end: end) { showDetail(.init(id: id)) }
            }
          }
        }
        .padding(.leading, 10)
        .padding(.top, 6)
        .overlay(alignment: .leading) {
          Rectangle().fill(.quaternary).frame(width: 1).padding(.top, 6)
        }
        .transition(.opacity)
      }
    }
    .font(.footnote)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var summary: some View {
    if let running = steps.running {
      HStack(spacing: 5) {
        MirrorHourglassIndicator().foregroundStyle(.orange)
        Text(MirrorToolKindStyle.title(running)).lineLimit(1)
      }
    } else {
      HStack(spacing: 4) {
        Text("^[\(steps.toolCount) tool call](inflect: true)")
        if steps.failedCount > 0 {
          Text("·")
          Text("\(steps.failedCount) failed").foregroundStyle(.red)
        }
      }
    }
  }
}

private struct StepLine: View {
  let start: MirrorConversationEvent.ToolStart
  let end: MirrorConversationEvent.ToolEnd?
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(spacing: 8) {
        Image(systemName: MirrorToolKindStyle.symbol(start.kind)).frame(width: 16)
        Text(MirrorToolKindStyle.title(start)).lineLimit(1)
        Spacer(minLength: 4)
        status
      }
      .padding(.vertical, 5)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("conversation-tool")
    .help("Show the command, output and changes")
  }

  @ViewBuilder private var status: some View {
    switch end?.status {
    case .succeeded?:
      if let code = end?.exitCode, code != 0 {
        Text("exit \(code)").foregroundStyle(.red)
      } else if let duration = end?.durationMs, duration >= 1000 {
        Text(Duration.milliseconds(duration), format: .units(allowed: [.seconds, .minutes], width: .narrow))
          .foregroundStyle(.tertiary)
      }
    case .error?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case .interrupted?: Image(systemName: "stop.circle").foregroundStyle(.orange)
    case nil: MirrorHourglassIndicator().foregroundStyle(.orange)
    }
  }
}

/// One tool call in full: its command or path, its changes and its output.
private struct ToolDetailView: View {
  let detail: ToolDetail
  /// Read here, not passed in as a value, so the sheet observes the call finishing.
  @Bindable var session: MirrorSession
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    if let tool = session.conversation.tool(id: detail.id) {
      content(start: tool.start, end: tool.end)
    } else {
      ContentUnavailableView("This tool call is no longer here", systemImage: "wrench.and.screwdriver")
    }
  }

  private func content(start: MirrorConversationEvent.ToolStart, end: MirrorConversationEvent.ToolEnd?)
    -> some View
  {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let command = start.command, !command.isEmpty {
            block(String(localized: "Command"), command)
          } else if let path = start.path {
            block(String(localized: "File"), path)
          }
          if let diff = end?.diff, !diff.text.isEmpty {
            block(String(localized: "Changes"), diff.text, truncated: diff.truncated)
          }
          if let output = end?.output, !output.text.isEmpty {
            block(String(localized: "Output"), output.text, truncated: output.truncated)
          }
          if end == nil {
            Label("Running", systemImage: "hourglass").foregroundStyle(.secondary)
          }
        }
        .padding()
      }
      .navigationTitle(MirrorToolKindStyle.title(start))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", systemImage: "checkmark") { dismiss() }
        }
      }
    }
  }

  private func block(_ title: String, _ text: String, truncated: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      ScrollView(.horizontal, showsIndicators: false) {
        Text(text).font(.footnote.monospaced()).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
          .padding(10)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
      if truncated { Text("Truncated by the Host.").font(.caption2).foregroundStyle(.secondary) }
    }
  }
}

enum MirrorToolKindStyle {
  /// A tool's name for a line: its title without the shell wrapper Codex puts around every
  /// command (`/bin/zsh -lc …`).
  nonisolated static func title(_ start: MirrorConversationEvent.ToolStart) -> String {
    let title = start.title.isEmpty ? start.name : start.title
    for wrapper in ["/bin/zsh -lc ", "/bin/bash -lc ", "/bin/sh -c ", "zsh -lc ", "bash -lc ", "sh -c "]
    where title.hasPrefix(wrapper) {
      return String(title.dropFirst(wrapper.count))
    }
    return title
  }

  static func symbol(_ kind: MirrorConversationEvent.ToolKind) -> String {
    switch kind {
    case .shell: "terminal"
    case .edit: "pencil"
    case .read: "doc.text"
    case .search: "magnifyingglass"
    case .web: "globe"
    case .mcp: "puzzlepiece.extension"
    case .agent: "person.2"
    case .question: "questionmark.bubble"
    case .plan: "list.clipboard"
    case .skill: "sparkles"
    case .other: "wrench.and.screwdriver"
    }
  }
}

private struct PromptCard: View {
  let prompt: MirrorConversationEvent.Prompt
  let resolved: MirrorConversationEvent.Prompt

  var body: some View {
    Label {
      Text("\(prompt.title ?? prompt.questions?.first?.question ?? title) · \(outcomeLabel(resolved.outcome))")
        .lineLimit(2)
    } icon: {
      Image(systemName: "checkmark.circle")
    }
    .font(.footnote).foregroundStyle(.secondary)
    .accessibilityIdentifier("conversation-prompt")
  }

  private var title: String {
    switch prompt.kind {
    case .permission: String(localized: "Permission requested")
    case .question: String(localized: "Question")
    case .planApproval: String(localized: "Plan approval")
    case .auth: String(localized: "Sign-in needed")
    case .trust: String(localized: "Trust requested")
    case .elicitation: String(localized: "Input requested")
    }
  }

  private func outcomeLabel(_ outcome: MirrorConversationEvent.PromptOutcome?) -> String {
    switch outcome {
    case .allowed: String(localized: "Allowed")
    case .denied: String(localized: "Denied")
    case .answered: String(localized: "Answered")
    case .dismissed: String(localized: "Dismissed")
    case .unknown, nil: String(localized: "Resolved")
    }
  }
}

private struct SessionDivider: View {
  let text: String

  init(text: String) { self.text = text }

  init(kind: MirrorConversationEvent.Kind, session: MirrorConversationEvent.Session?) {
    switch kind {
    case .sessionStarted:
      let model = session?.model.map { " · \($0)" } ?? ""
      text = String(localized: "Session started") + model
    case .sessionChanged: text = String(localized: "New session")
    case .sessionPending: text = String(localized: "Waiting for the session")
    case .sessionEnded: text = String(localized: "Session ended")
    default: text = ""
    }
  }

  var body: some View {
    Text(text)
      .font(.caption2.weight(.medium))
      .foregroundStyle(.tertiary)
      .lineLimit(1)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 2)
  }
}

extension MirrorConversationEvent.Question: Identifiable {}
extension MirrorConversationEvent.Choice: Identifiable {}
