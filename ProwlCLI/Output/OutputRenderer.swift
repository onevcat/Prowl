// ProwlCLI/Output/OutputRenderer.swift
// Renders command responses for terminal output.

import Foundation
import ProwlCLIShared
import Rainbow

enum OutputRenderer {
  static func render(_ response: CommandResponse, mode: OutputMode) {
    switch mode {
    case .json:
      renderJSON(response)
    case .text:
      renderText(response)
    }
  }

  static func renderError(code: String, message: String, command: String, mode: OutputMode) {
    let response = CommandResponse(
      ok: false,
      command: command,
      schemaVersion: "prowl.cli.\(command).v1",
      error: CommandError(code: code, message: message)
    )
    render(response, mode: mode)
  }

  // MARK: - JSON

  private static func renderJSON(_ response: CommandResponse) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(response),
       let jsonString = String(data: data, encoding: .utf8)
    {
      print(jsonString)
    }
  }

  // MARK: - Text

  private static func renderText(_ response: CommandResponse) {
    if response.ok {
      if response.command == "list",
         let data = response.data,
         let payload = try? data.decode(as: ListCommandPayload.self)
      {
        print(renderList(payload))
        return
      }

      if response.command == "send",
         let data = response.data,
         let payload = try? data.decode(as: SendCommandPayload.self)
      {
        print(renderSend(payload))
        return
      }

      if response.command == "agents",
         let data = response.data,
         let payload = try? data.decode(as: AgentsCommandPayload.self)
      {
        print(renderAgents(payload))
        return
      }

      if response.command == "focus",
         let data = response.data,
         let payload = try? data.decode(as: FocusCommandPayload.self)
      {
        print(renderFocus(payload))
        return
      }

      if response.command == "key",
         let data = response.data,
         let payload = try? data.decode(as: KeyCommandPayload.self)
      {
        print(renderKey(payload))
        return
      }

      if response.command == "read",
         let data = response.data,
         let payload = try? data.decode(as: ReadCommandPayload.self)
      {
        print(renderRead(payload))
        return
      }

      if response.command == "tab",
         let data = response.data,
         let payload = try? data.decode(as: TabCommandPayload.self)
      {
        print(renderTab(payload))
        return
      }

      if response.command == "pane",
         let data = response.data,
         let payload = try? data.decode(as: PaneCommandPayload.self)
      {
        print(renderPane(payload))
        return
      }

      if response.command == "scripts",
         let data = response.data,
         let payload = try? data.decode(as: ScriptProfilesPayload.self)
      {
        print(renderScriptProfiles(payload))
        return
      }

      if response.command == "scripts",
         let data = response.data,
         let payload = try? data.decode(as: ScriptProfilePayload.self)
      {
        print(renderScriptProfile(payload))
        return
      }

      if response.command == "scripts",
         let data = response.data,
         let payload = try? data.decode(as: ScriptDeletePayload.self)
      {
        print("Deleted script profile \(payload.id).")
        return
      }

      if response.command == "open" {
        return
      }

      print("ok: \(response.command)")
      return
    }

    if let error = response.error {
      FileHandle.standardError.write(
        Data("error [\(error.code)]: \(error.message)\n".utf8)
      )
    }
  }

  private static func renderList(_ payload: ListCommandPayload) -> String {
    guard !payload.items.isEmpty else {
      return "No panes found."
    }

    // Group items by worktree, preserving order of first appearance.
    var worktreeOrder: [String] = []
    var worktreeGroups: [String: [ListCommandItem]] = [:]
    for item in payload.items {
      let key = item.worktree.id
      if worktreeGroups[key] == nil {
        worktreeOrder.append(key)
      }
      worktreeGroups[key, default: []].append(item)
    }

    var lines: [String] = []

    for (index, worktreeID) in worktreeOrder.enumerated() {
      guard let items = worktreeGroups[worktreeID], let first = items.first else { continue }

      if index > 0 {
        lines.append("")
      }

      // Worktree header: "ProjectName:branch (status)"
      let projectName = projectName(from: first.worktree.path)
      let statusText: String
      switch first.task.status {
      case .running:
        statusText = "running".green
      case .idle:
        statusText = "idle".dim
      case nil:
        statusText = "n/a".dim
      }
      lines.append(
        "\(projectName.cyan.bold)\(":".dim)\(first.worktree.name) (\(statusText))  \(first.worktree.id.dim)"
      )
      lines.append("  \("path:".dim) \(first.worktree.path)")

      // Group panes by tab within this worktree.
      var tabOrder: [String] = []
      var tabGroups: [String: [ListCommandItem]] = [:]
      for item in items {
        let tabKey = item.tab.id
        if tabGroups[tabKey] == nil {
          tabOrder.append(tabKey)
        }
        tabGroups[tabKey, default: []].append(item)
      }

      let worktreePath = normalizeTrailingSlash(first.worktree.path)

      for (tabIndex, tabID) in tabOrder.enumerated() {
        guard let tabItems = tabGroups[tabID], let firstTab = tabItems.first else { continue }

        let tabNum = "Tab \(tabIndex + 1):"
        let tabHandle = firstTab.tab.handle.map { "t\($0)" } ?? firstTab.tab.id
        let selectedMark = firstTab.tab.selected ? "*".yellow : " "
        let tabTitle = firstTab.tab.selected ? firstTab.tab.title.yellow : firstTab.tab.title
        lines.append("  [\(selectedMark)] \(tabNum.dim) \(tabTitle)  \(tabHandle.dim)")

        for (paneIndex, item) in tabItems.enumerated() {
          let focusMark = item.pane.focused ? ">".green.bold : " "
          let paneNum = item.pane.focused ? "Pane \(paneIndex + 1):".green : "Pane \(paneIndex + 1):".dim
          let paneTitle = item.pane.focused ? item.pane.title.green.bold : item.pane.title.dim

          var paneLine = "      \(focusMark) \(paneNum) \(paneTitle)"

          // Only show cwd when it differs from the worktree path.
          if let cwd = item.pane.cwd, normalizeTrailingSlash(cwd) != worktreePath {
            paneLine += "  \(cwd.dim)"
          }

          let paneHandle = item.pane.handle.map { "p\($0)" } ?? item.pane.id
          paneLine += "  \(paneHandle.dim)"
          lines.append(paneLine)
        }
      }
    }

    return lines.joined(separator: "\n")
  }

  private static func renderAgents(_ payload: AgentsCommandPayload) -> String {
    guard !payload.agents.isEmpty else {
      return "No agents found."
    }

    let order: [AgentsCommandStatus: Int] = [
      .blocked: 0,
      .working: 1,
      .done: 2,
      .idle: 3,
    ]
    let indexedAgents = payload.agents.enumerated()
    let sortedAgents = indexedAgents.sorted { left, right in
      let leftRank = order[left.element.status] ?? Int.max
      let rightRank = order[right.element.status] ?? Int.max
      if leftRank != rightRank {
        return leftRank < rightRank
      }
      return left.offset < right.offset
    }.map(\.element)

    return sortedAgents.map { agent in
      let statusLabel = agentStatusLabel(agent.status)
      let projectLabel = "\(agent.project.name):\(agent.project.branch)"
      let paneHandle = agent.pane.handle.map { "p\($0)" } ?? agent.pane.id
      let sessionLabel = agent.session.map { "  session=\($0.id) [\($0.confidence)]" } ?? ""
      return "\(statusLabel)  \(agent.name)  \(projectLabel)  \(agent.tab.title)  \(paneHandle)\(sessionLabel)"
    }.joined(separator: "\n")
  }

  private static func renderScriptProfiles(_ payload: ScriptProfilesPayload) -> String {
    guard !payload.profiles.isEmpty else {
      return "No script profiles found at \(payload.path)."
    }
    return payload.profiles.map { profile in
      let title = profile.name.isEmpty || profile.name == profile.id
        ? profile.id
        : "\(profile.name) (\(profile.id))"
      return "\(title)\n  command: \(profile.command)\n  timeout: \(profile.timeoutSeconds)s"
    }
    .joined(separator: "\n")
  }

  private static func renderScriptProfile(_ payload: ScriptProfilePayload) -> String {
    "Saved script profile \(payload.profile.id) at \(payload.path)."
  }

  private static func agentStatusLabel(_ status: AgentsCommandStatus) -> String {
    switch status {
    case .blocked:
      return "Blocked".red.bold
    case .working:
      return "Working".green
    case .done:
      return "Done".dim
    case .idle:
      return "Idle".dim
    }
  }

  private static func renderTab(_ payload: TabCommandPayload) -> String {
    let wt = payload.target.worktree
    let tab = payload.target.tab
    let pane = payload.target.pane
    let projectName = projectName(from: wt.path)
    let verb =
      switch payload.action {
      case .create: "Created tab"
      case .close: "Closed tab"
      }

    var lines: [String] = []
    lines.append(
      "\(verb) \(projectName.cyan.bold)\(":".dim)\(wt.name) → \(tab.title.yellow)"
      + "  \(tab.id.dim)"
    )
    lines.append("  \("pane:".dim) \(pane.title.green)  \(pane.id.dim)")
    if let cwd = pane.cwd {
      lines.append("  \("cwd:".dim) \(cwd)")
    }
    return lines.joined(separator: "\n")
  }

  private static func renderPane(_ payload: PaneCommandPayload) -> String {
    let wt = payload.target.worktree
    let pane = payload.target.pane
    let projectName = projectName(from: wt.path)
    let verb =
      switch payload.action {
      case .close: "Closed pane"
      }

    var lines: [String] = []
    lines.append(
      "\(verb) \(projectName.cyan.bold)\(":".dim)\(wt.name) → \(pane.title.green)"
      + "  \(pane.id.dim)"
    )
    if let cwd = pane.cwd {
      lines.append("  \("cwd:".dim) \(cwd)")
    }
    return lines.joined(separator: "\n")
  }

  private static func renderSend(_ payload: SendCommandPayload) -> String {
    let wt = payload.target.worktree
    let pane = payload.target.pane
    let input = payload.input

    let projectName = projectName(from: wt.path)
    var lines: [String] = []

    lines.append(
      "Sent to \(projectName.cyan.bold)\(":".dim)\(wt.name) → \(pane.title.green)"
      + "  \(pane.id.dim)"
    )

    let enterLabel = input.trailingEnterSent ? "yes".green : "no".dim
    lines.append(
      "  \("source:".dim) \(input.source)"
      + "  \("chars:".dim) \(input.characters)"
      + "  \("bytes:".dim) \(input.bytes)"
      + "  \("enter:".dim) \(enterLabel)"
    )

    if let wait = payload.wait {
      let exitLabel: String
      if let code = wait.exitCode {
        exitLabel = code == 0 ? "0".green : "\(code)".red.bold
      } else {
        exitLabel = "n/a".dim
      }
      let durationLabel = formatDurationMs(wait.durationMs)
      lines.append("  \("exit:".dim) \(exitLabel)  \("duration:".dim) \(durationLabel)")
    } else {
      lines.append("  \("wait:".dim) \("none (fire-and-forget)".dim)")
    }

    if let capture = payload.capture {
      let truncLabel = capture.truncated ? " (truncated)".yellow : ""
      lines.append(
        "  \("capture:".dim) \(capture.lineCount) lines"
        + " (\(capture.source.rawValue)\(truncLabel))"
      )
      if !capture.text.isEmpty {
        lines.append("  \("--- output ---".dim)")
        let outputLines = capture.text.split(separator: "\n", omittingEmptySubsequences: false)
        let maxDisplay = 100
        for line in outputLines.prefix(maxDisplay) {
          lines.append("  \(line)")
        }
        if outputLines.count > maxDisplay {
          lines.append("  \("... (\(outputLines.count - maxDisplay) more lines)".dim)")
        }
      }
    }

    return lines.joined(separator: "\n")
  }

  private static func renderFocus(_ payload: FocusCommandPayload) -> String {
    let wt = payload.target.worktree
    let tab = payload.target.tab
    let pane = payload.target.pane

    let projectName = projectName(from: wt.path)
    let frontLabel = payload.broughtToFront ? "yes".green : "no".red.bold
    let requestedValue = payload.requested.value ?? "current"

    var lines: [String] = []
    lines.append(
      "Focused \(projectName.cyan.bold)\(":".dim)\(wt.name) → \(pane.title.green)"
      + "  \(pane.id.dim)"
    )
    lines.append(
      "  \("requested:".dim) \(payload.requested.selector.rawValue)=\(requestedValue)"
      + "  \("resolved:".dim) \(payload.resolvedVia.rawValue)"
      + "  \("front:".dim) \(frontLabel)"
    )
    lines.append("  \("tab:".dim) \(tab.title)  \(tab.id.dim)")
    if let cwd = pane.cwd {
      lines.append("  \("cwd:".dim) \(cwd)")
    }
    return lines.joined(separator: "\n")
  }

  private static func renderKey(_ payload: KeyCommandPayload) -> String {
    let wt = payload.target.worktree
    let pane = payload.target.pane

    let projectName = projectName(from: wt.path)
    var lines: [String] = []

    lines.append(
      "Key sent to \(projectName.cyan.bold)\(":".dim)\(wt.name) → \(pane.title.green)"
      + "  \(pane.id.dim)"
    )

    let categoryLabel = payload.key.category.rawValue
    let deliveredLabel =
      payload.delivery.delivered == payload.delivery.attempted
      ? "\(payload.delivery.delivered)".green
      : "\(payload.delivery.delivered)".red.bold
    lines.append(
      "  \("token:".dim) \(payload.key.normalized)"
      + "  \("category:".dim) \(categoryLabel)"
      + "  \("repeat:".dim) \(payload.requested.repeat)"
      + "  \("delivered:".dim) \(deliveredLabel)/\(payload.delivery.attempted)"
    )

    return lines.joined(separator: "\n")
  }

  private static func renderRead(_ payload: ReadCommandPayload) -> String {
    let wt = payload.target.worktree
    let pane = payload.target.pane
    let projectName = projectName(from: wt.path)

    let requestedLabel: String
    if let last = payload.last {
      requestedLabel = "last \(last)"
    } else {
      requestedLabel = "snapshot"
    }
    let truncatedLabel = payload.truncated ? "yes".yellow : "no".green

    var lines: [String] = []
    lines.append(
      "Read from \(projectName.cyan.bold)\(":".dim)\(wt.name) → \(pane.title.green)"
      + "  \(pane.id.dim)"
    )
    lines.append(
      "  \("mode:".dim) \(payload.mode.rawValue)"
      + " (\(requestedLabel))"
      + "  \("source:".dim) \(payload.source.rawValue)"
      + "  \("truncated:".dim) \(truncatedLabel)"
      + "  \("lines:".dim) \(payload.lineCount)"
    )

    if let stabilized = payload.stabilized {
      let stableLabel = stabilized ? "yes".green : "timed out".yellow
      lines.append(
        "  \("stable:".dim) \(stableLabel)"
        + "  \("waited:".dim) \(formatDurationMs(payload.waitedMs ?? 0))"
        + "  \("samples:".dim) \(payload.samples ?? 0)"
      )
    }

    if let cwd = pane.cwd {
      lines.append("  \("cwd:".dim) \(cwd)")
    }

    if !payload.text.isEmpty {
      lines.append("")
      lines.append(payload.text)
    }

    return lines.joined(separator: "\n")
  }

  private static func formatDurationMs(_ ms: Int) -> String {
    if ms < 1000 {
      return "\(ms)ms"
    }
    let seconds = ms / 1000
    if seconds < 60 {
      return "\(seconds).\(String(format: "%03d", ms % 1000))s"
    }
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    return remainingSeconds > 0 ? "\(minutes)m \(remainingSeconds)s" : "\(minutes)m"
  }

  private static func projectName(from path: String) -> String {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    return trimmed.split(separator: "/").last.map(String.init) ?? path
  }

  private static func normalizeTrailingSlash(_ path: String) -> String {
    path.hasSuffix("/") ? String(path.dropLast()) : path
  }
}
