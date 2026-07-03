import Foundation

struct TelegramBotResponseFormatter: Sendable {
  let maxMessageLength: Int

  init(maxMessageLength: Int = 3900) {
    self.maxMessageLength = max(80, maxMessageLength)
  }

  func format(_ response: CommandResponse) -> String {
    guard response.ok else {
      if let error = response.error {
        return truncate("Error [\(error.code)]: \(error.message)")
      }
      return truncate("Error: \(response.command) failed.")
    }

    switch response.command {
    case "agents":
      return formatPayload(response, as: AgentsCommandPayload.self, fallback: "Agents command completed.") {
        formatAgents($0)
      }
    case "list":
      return formatPayload(response, as: ListCommandPayload.self, fallback: "List command completed.") {
        formatList($0)
      }
    case "read":
      return formatPayload(response, as: ReadCommandPayload.self, fallback: "Read command completed.") {
        formatRead($0)
      }
    case "focus":
      return formatPayload(response, as: FocusCommandPayload.self, fallback: "Focus command completed.") {
        "Focused \($0.target.pane.id) in \($0.target.worktree.name)."
      }
    case "send":
      return formatPayload(response, as: SendCommandPayload.self, fallback: "Send command completed.") {
        "Sent to \($0.target.pane.id). Use /read \($0.target.pane.id) to inspect output."
      }
    case "key":
      return formatPayload(response, as: KeyCommandPayload.self, fallback: "Key command completed.") {
        "Sent \($0.key.normalized) to \($0.target.pane.id)."
      }
    case "tab":
      return formatPayload(response, as: TabCommandPayload.self, fallback: "Tab command completed.") {
        switch $0.action {
        case .create:
          return "Created tab \($0.target.tab.id) in \($0.target.worktree.name)."
        case .close:
          return "Closed tab \($0.target.tab.id)."
        }
      }
    case "pane":
      return formatPayload(response, as: PaneCommandPayload.self, fallback: "Pane command completed.") {
        "Closed pane \($0.target.pane.id)."
      }
    default:
      return truncate("OK: \(response.command)")
    }
  }

  private func formatPayload<Payload: Decodable>(
    _ response: CommandResponse,
    as payloadType: Payload.Type,
    fallback: String,
    render: (Payload) -> String
  ) -> String {
    guard let data = response.data, let payload = try? data.decode(as: payloadType) else {
      return truncate(fallback)
    }
    return truncate(render(payload), hint: truncationHint(for: payload))
  }

  private func formatAgents(_ payload: AgentsCommandPayload) -> String {
    guard !payload.agents.isEmpty else { return "No agents found." }
    return payload.agents.map { agent in
      "\(agent.status.rawValue)  \(agent.name)  \(agent.project.name):\(agent.project.branch)  \(agent.pane.id)"
    }
    .joined(separator: "\n")
  }

  private func formatList(_ payload: ListCommandPayload) -> String {
    guard !payload.items.isEmpty else { return "No panes found." }
    return payload.items.map { item in
      let marker = item.pane.focused ? ">" : "-"
      return "\(marker) \(item.worktree.name) / \(item.tab.title) / \(item.pane.title)  \(item.pane.id)"
    }
    .joined(separator: "\n")
  }

  private func formatRead(_ payload: ReadCommandPayload) -> String {
    let title = "\(payload.target.worktree.name) / \(payload.target.tab.title) / \(payload.target.pane.title)"
    let header = "\(title) (\(payload.target.pane.id))"
    let body = payload.text.isEmpty ? "(empty)" : payload.text
    return "\(header)\n\(body)"
  }

  private func truncate(_ text: String, hint: String? = nil) -> String {
    guard text.count > maxMessageLength else { return text }
    let suffix = "\n\n[Truncated] \(hint ?? "Try again with a narrower command.")"
    guard suffix.count < maxMessageLength else {
      return String(suffix.suffix(maxMessageLength))
    }
    let prefixLimit = maxMessageLength - suffix.count
    return String(text.prefix(prefixLimit)) + suffix
  }

  private func truncationHint<Payload>(for payload: Payload) -> String? {
    if let readPayload = payload as? ReadCommandPayload {
      return "Try /read \(readPayload.target.pane.id) with fewer lines."
    }
    return nil
  }
}
