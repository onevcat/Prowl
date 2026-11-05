import SwiftUI

/// The chat: user bubbles, assistant Markdown, tool cards, prompts, dividers (docs-ai 088).
struct ConversationView: View {
  @Bindable var session: MirrorSession
  @State private var follows = true
  @State private var expandedTools: Set<UInt64> = []
  /// Items are laid out eagerly so the bottom anchor never lands on an unsized lazy row;
  /// older items load in pages on request instead.
  @State private var visibleLimit = ConversationView.page

  private static let page = 120
  private var store: MirrorConversationStore { session.conversation }
  private var hiddenCount: Int { max(0, store.items.count - visibleLimit) }
  private var visibleItems: ArraySlice<MirrorConversationItem> { store.items.suffix(visibleLimit) }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if store.gap {
            Text("Earlier messages are not available on this device.")
              .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
          }
          if hiddenCount > 0 {
            Button("Show \(min(hiddenCount, Self.page)) earlier") { visibleLimit += Self.page }
              .buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
              .accessibilityIdentifier("conversation-earlier")
          }
          if store.isEmpty, session.status == .live {
            ContentUnavailableView(
              "Waiting for the agent", systemImage: "bubble.left.and.text.bubble.right",
              description: Text("Messages appear here as the agent and you exchange them."))
          }
          ForEach(visibleItems) { item in
            ConversationItemView(item: item, expanded: binding(for: item.id))
              .id(item.id)
          }
          if session.agentState == .working {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("Working…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .accessibilityIdentifier("conversation-working")
          }
          Color.clear.frame(height: 1).id("conversation-bottom")
        }
        .padding()
      }
      .defaultScrollAnchor(.bottom)
      .accessibilityIdentifier("conversation-scroll")
      .onScrollPhaseChange { _, phase in
        if phase == .interacting { follows = false }
      }
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
      } action: { _, atBottom in
        if atBottom { follows = true }
      }
      .onChange(of: store.latestSequence) { _, _ in
        if follows { withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
      }
      .overlay(alignment: .bottomTrailing) {
        if !follows {
          Button {
            follows = true
            withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
          } label: {
            Label("Latest", systemImage: "arrow.down")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .padding()
          .accessibilityIdentifier("conversation-latest")
        }
      }
    }
  }

  private func binding(for id: UInt64) -> Binding<Bool> {
    Binding(
      get: { expandedTools.contains(id) },
      set: { expanded in
        if expanded { expandedTools.insert(id) } else { expandedTools.remove(id) }
      })
  }
}

struct ConversationItemView: View {
  let item: MirrorConversationItem
  @Binding var expanded: Bool

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
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
      .frame(maxWidth: .infinity, alignment: .trailing)
      .accessibilityLabel("Queued: \(MirrorInjectedText.split(text).message)")
    case .assistant(_, let text, _, let at):
      AssistantBubble(text: text, at: at)
    case .reasoning(_, let durationMs, let summary):
      HStack(spacing: 6) {
        Image(systemName: "brain")
        if let summary, !summary.text.isEmpty {
          Text(summary.text).lineLimit(2)
        } else if let durationMs {
          Text(
            "Thought for \(Duration.milliseconds(durationMs).formatted(.units(allowed: [.seconds], width: .narrow)))")
        } else {
          Text("Thinking")
        }
      }
      .font(.caption).foregroundStyle(.secondary)
    case .tool(_, let start, let end, let startedAt, let endedAt):
      ToolCard(start: start, end: end, startedAt: startedAt, endedAt: endedAt, expanded: $expanded)
    case .prompt(_, let prompt, let resolved, _):
      PromptCard(prompt: prompt, resolved: resolved)
    case .attention(_, let status, _):
      Label(attentionText(status), systemImage: "exclamationmark.circle.fill")
        .font(.callout).foregroundStyle(.red)
    case .session(_, let kind, let session, _):
      SessionDivider(kind: kind, session: session)
    case .compaction:
      Divider().overlay {
        Text("Context compacted").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6)
          .background(Color(.systemBackground))
      }
    case .subagent(_, let kind, let agent):
      Label(
        "\(agent.type ?? "Subagent") \(kind == .subagentStarted ? "started" : "finished")",
        systemImage: "person.2"
      )
      .font(.caption).foregroundStyle(.secondary)
    case .notice(_, let notice, _):
      Label(notice.text, systemImage: notice.level == .warning ? "exclamationmark.triangle" : "info.circle")
        .font(.caption).foregroundStyle(notice.level == .warning ? .orange : .secondary)
    }
  }

  private func attentionText(_ status: MirrorConversationEvent.Status) -> String {
    switch status.kind {
    case "permission": String(localized: "Waiting for a permission decision on the Mac")
    case "question": String(localized: "Waiting for your answer on the Mac")
    case "auth": String(localized: "Waiting for sign-in on the Mac")
    default: String(localized: "Waiting for you on the Mac")
    }
  }
}

private struct UserBubble: View {
  let text: MirrorBoundedText
  let origin: MirrorConversationEvent.MessageOrigin?
  let images: Int?
  let at: Date?
  @State private var showsInjected = false

  var body: some View {
    let parts = MirrorInjectedText.split(text.text)
    VStack(alignment: .trailing, spacing: 4) {
      VStack(alignment: .leading, spacing: 6) {
        if let images, images > 0 {
          Label("\(images) image(s)", systemImage: "photo").font(.caption).opacity(0.8)
        }
        Text(parts.message).textSelection(.enabled)
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
      .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
      HStack(spacing: 4) {
        if let origin, origin != .human { Text(originLabel(origin)) }
        if let at { Text(at, style: .time) }
      }
      .font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.leading, 40)
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

private struct AssistantBubble: View {
  let text: MirrorBoundedText
  let at: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      MirrorMarkdownView(text: text.text)
      if text.truncated {
        Text("Message truncated by the Host.").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.trailing, 24)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversation-assistant")
  }
}

private struct ToolCard: View {
  let start: MirrorConversationEvent.ToolStart
  let end: MirrorConversationEvent.ToolEnd?
  let startedAt: Date?
  let endedAt: Date?
  @Binding var expanded: Bool

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        if let command = start.command, !command.isEmpty {
          code(command, label: String(localized: "Command"))
        } else if let path = start.path {
          Text(path).font(.caption.monospaced()).textSelection(.enabled)
        }
        if let diff = end?.diff, !diff.text.isEmpty {
          code(diff.text, label: String(localized: "Changes"), truncated: diff.truncated)
        }
        if let output = end?.output, !output.text.isEmpty {
          code(output.text, label: String(localized: "Output"), truncated: output.truncated)
        }
        if end == nil, start.kind != .question {
          Label("Running", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.top, 6)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(start.title.isEmpty ? start.name : start.title)
            .font(.callout).lineLimit(2).multilineTextAlignment(.leading)
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        statusIcon
      }
      .foregroundStyle(.primary)
    }
    .tint(.secondary)
    .padding(12)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversation-tool")
  }

  private var icon: String {
    switch start.kind {
    case .shell: "terminal"
    case .edit: "pencil.line"
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

  private var subtitle: String {
    var parts = [start.name]
    if let end {
      switch end.status {
      case .succeeded: if let code = end.exitCode, code != 0 { parts.append("exit \(code)") }
      case .error: parts.append(String(localized: "failed"))
      case .interrupted: parts.append(String(localized: "interrupted"))
      }
      if let duration = end.durationMs, duration >= 1000 {
        parts.append(Duration.milliseconds(duration).formatted(.units(allowed: [.seconds], width: .narrow)))
      }
    } else if let startedAt {
      parts.append(startedAt.formatted(date: .omitted, time: .shortened))
    }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder private var statusIcon: some View {
    if let end {
      switch end.status {
      case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
      case .interrupted: Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
      }
    } else {
      ProgressView().controlSize(.small)
    }
  }

  private func code(_ text: String, label: String, truncated: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      ScrollView(.horizontal) {
        Text(text).font(.caption.monospaced()).textSelection(.enabled).lineLimit(40)
      }
      if truncated { Text("Truncated by the Host.").font(.caption2).foregroundStyle(.secondary) }
    }
    .padding(8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct PromptCard: View {
  let prompt: MirrorConversationEvent.Prompt
  let resolved: MirrorConversationEvent.Prompt?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: icon).font(.headline).foregroundStyle(resolved == nil ? .orange : .secondary)
      if let detail = prompt.detail { Text(detail.text).font(.callout) }
      ForEach(prompt.questions ?? []) { question in
        VStack(alignment: .leading, spacing: 4) {
          if let header = question.header { Text(header).font(.caption).foregroundStyle(.secondary) }
          Text(question.question).font(.callout)
          ForEach(question.options) { option in
            HStack(alignment: .top, spacing: 6) {
              Image(systemName: "circle").font(.caption2).padding(.top, 3)
              VStack(alignment: .leading) {
                Text(option.label).font(.callout)
                if let description = option.description {
                  Text(description).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }
      ForEach(prompt.choices ?? []) { choice in
        Label(choice.label, systemImage: "circle").font(.callout)
      }
      if let resolved {
        Label(outcomeLabel(resolved.outcome), systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Answer on the Mac.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(resolved == nil ? Color.orange : Color.clear))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversation-prompt")
  }

  private var title: String {
    switch prompt.kind {
    case .permission: String(localized: "Permission requested")
    case .question: String(localized: "The agent has a question")
    case .planApproval: String(localized: "Plan ready for approval")
    case .auth: String(localized: "Sign-in needed")
    case .trust: String(localized: "Trust requested")
    case .elicitation: String(localized: "Input requested")
    }
  }

  private var icon: String {
    switch prompt.kind {
    case .permission, .trust: "lock.shield"
    case .question, .elicitation: "questionmark.bubble"
    case .planApproval: "list.clipboard"
    case .auth: "person.badge.key"
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
  let kind: MirrorConversationEvent.Kind
  let session: MirrorConversationEvent.Session?

  var body: some View {
    HStack {
      Rectangle().fill(.quaternary).frame(height: 1)
      Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
      Rectangle().fill(.quaternary).frame(height: 1)
    }
  }

  private var text: String {
    switch kind {
    case .sessionStarted:
      let model = session?.model.map { " · \($0)" } ?? ""
      return String(localized: "Session started") + model
    case .sessionChanged: return String(localized: "New session")
    case .sessionPending: return String(localized: "Waiting for the session")
    case .sessionEnded: return String(localized: "Session ended")
    default: return ""
    }
  }
}

extension MirrorConversationEvent.Question: Identifiable {}
extension MirrorConversationEvent.Choice: Identifiable {}
