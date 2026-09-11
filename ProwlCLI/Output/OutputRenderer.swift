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
    let schemaVersion = "prowl.cli.\(command).v1"
    let response = CommandResponse(
      ok: false,
      command: command,
      schemaVersion: schemaVersion,
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

      if response.command == "agents.read",
         let data = response.data,
         let payload = try? data.decode(as: AgentReadCommandPayload.self)
      {
        renderAgentsRead(payload)
        return
      }

      if response.command == "agents.signal",
         let data = response.data,
         let payload = try? data.decode(as: AgentSignalCommandPayload.self)
      {
        print(agentSignalText(payload))
        for line in agentSignalWarningLines(payload) {
          FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        return
      }

      if response.command == "agents.dispatch",
         let data = response.data,
         let payload = try? data.decode(as: AgentDispatchCommandPayload.self)
      {
        print(dispatchText(payload))
        return
      }

      if response.command == "agents.dispatch-complete",
         let data = response.data,
         let payload = try? data.decode(as: DispatchCompleteCommandPayload.self)
      {
        print(dispatchCompleteText(payload))
        return
      }

      if response.command == "agents.dispatch-abandon",
         let data = response.data,
         let payload = try? data.decode(as: DispatchAbandonCommandPayload.self)
      {
        print(dispatchAbandonText(payload))
        return
      }

      if response.command == "agents.wait",
         let data = response.data,
         let payload = try? data.decode(as: AgentWaitCommandPayload.self)
      {
        print(agentWaitText(payload))
        return
      }

      if response.command == "profiles",
         let data = response.data,
         let payload = try? data.decode(as: ProfilesCommandPayload.self)
      {
        print(renderProfiles(payload))
        return
      }

      if response.command == "skills",
         let data = response.data,
         let payload = try? data.decode(as: SkillsCommandPayload.self)
      {
        renderSkills(payload)
        return
      }

      if response.command == "workflow",
         let data = response.data,
         let payload = try? data.decode(as: WorkflowCommandPayload.self)
      {
        renderWorkflow(payload)
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

      if response.command == "create" || response.command == "close",
         let data = response.data,
         let payload = try? data.decode(as: LifecycleCommandPayload.self)
      {
        print(renderLifecycle(payload, command: response.command))
        renderLifecycleWarnings(payload)
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

      if response.command == "open" {
        return
      }

      print("ok: \(response.command)")
      return
    }

    if let error = response.error {
      FileHandle.standardError.write(
        Data("\(errorText(error, command: response.command))\n".utf8)
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

          // Show the detected coding agent (claude/codex/…) when present.
          if let agent = item.pane.agent, !agent.isEmpty {
            paneLine += "  \("⟦\(agent)⟧".dim)"
          }

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

  static func agentSignalWarningLines(_ payload: AgentSignalCommandPayload) -> [String] {
    (payload.warnings ?? []).map { "warning: [\($0.code.rawValue)] \($0.message)" }
  }

  static func agentSignalText(_ payload: AgentSignalCommandPayload) -> String {
    let event: String
    if payload.signal.event == .progress, let progress = payload.signal.progress {
      event = "progress=\(progress)"
    } else {
      event = payload.signal.event.rawValue
    }
    return "Signaled \(event) for pane \(payload.pane.id)."
  }

  static func dispatchText(_ payload: AgentDispatchCommandPayload) -> String {
    [
      "Dispatched \(payload.dispatch.id) (\(payload.dispatch.state.rawValue))",
      "  pane: \(payload.target.pane.id)",
      "  created: \(payload.dispatch.createdAt)",
    ].joined(separator: "\n")
  }

  static func dispatchCompleteText(_ payload: DispatchCompleteCommandPayload) -> String {
    let replayed = payload.replayed ? " (replayed)" : ""
    return [
      "Completed dispatch \(payload.receipt.id): \(payload.receipt.outcome.rawValue)\(replayed)",
      "  pane: \(payload.target.pane.id)",
      "  summary: \(payload.receipt.summary)",
    ].joined(separator: "\n")
  }

  static func dispatchAbandonText(_ payload: DispatchAbandonCommandPayload) -> String {
    let replayed = payload.replayed ? " (replayed)" : ""
    return [
      "Abandoned dispatch \(payload.record.id)\(replayed)",
      "  pane: \(payload.target.pane.id)",
      "  reason: \(payload.record.reason)",
    ].joined(separator: "\n")
  }

  static func agentWaitText(_ payload: AgentWaitCommandPayload) -> String {
    switch payload {
    case .dispatch(let wait):
      return [
        "Dispatch \(wait.receipt.id) \(wait.receipt.outcome.rawValue) after \(wait.waitedMilliseconds) ms",
        "  pane: \(wait.target.pane.id)",
        "  summary: \(wait.receipt.summary)",
      ].joined(separator: "\n")
    case .condition(let wait):
      return [
        "Agent reached \(wait.condition.rawValue) after \(wait.waitedMilliseconds) ms",
        "  pane: \(wait.target.pane.id)",
        "  observation: \(wait.observation.status.rawValue) [\(wait.observation.confidence)] via \(wait.observation.source)",
      ].joined(separator: "\n")
    }
  }

  static func errorText(_ error: CommandError, command: String) -> String {
    var lines = ["error [\(error.code)]: \(error.message)"]
    if command == "agents.dispatch",
      let details = try? error.details?.decode(as: AgentDispatchErrorDetails.self)
    {
      lines.append("  pane: \(details.target.pane.id)")
      if let record = details.record {
        lines.append("  dispatch: \(record.id) (\(record.state.rawValue))")
      }
      if let observation = details.observation {
        lines.append(
          "  observation: \(observation.status.rawValue) [\(observation.confidence)] via \(observation.source)"
        )
      }
      return lines.joined(separator: "\n")
    }
    guard command == "agents.wait",
      let details = try? error.details?.decode(as: AgentWaitErrorDetails.self)
    else {
      return lines[0]
    }

    switch details {
    case .dispatch(let wait):
      lines.append("  dispatch: \(wait.record.id) (\(wait.record.state.rawValue))")
      lines.append("  pane: \(wait.target.pane.id)")
      lines.append("  waited: \(wait.waitedMilliseconds) ms")
    case .condition(let wait):
      lines.append("  condition: \(wait.condition.rawValue)")
      if let target = wait.target {
        lines.append("  pane: \(target.pane.id)")
      }
      if let observation = wait.observation {
        lines.append(
          "  observation: \(observation.status.rawValue) [\(observation.confidence)] via \(observation.source)"
        )
      }
      lines.append("  waited: \(wait.waitedMilliseconds) ms")
    }
    return lines.joined(separator: "\n")
  }

  private static func renderProfiles(_ payload: ProfilesCommandPayload) -> String {
    guard !payload.profiles.isEmpty else { return "No Agent Profiles found." }
    return payload.profiles.map { profile in
      let enabled = profile.enabled ? "enabled".green : "disabled".dim
      let availability: String
      switch profile.availability.status {
      case .available:
        availability = "available".green
      case .unavailable:
        availability = "unavailable".yellow
      case .unknown:
        availability = "unknown".dim
      }
      let reason = profile.availability.reason.map { "  \($0.dim)" } ?? ""
      return "\(profile.name.bold)  \(profile.runtime)  \(enabled)  \(availability)  \(profile.id.dim)\(reason)"
    }.joined(separator: "\n")
  }

  private static func renderSkills(_ payload: SkillsCommandPayload) {
    switch payload {
    case .list(let list):
      print(skillsListText(list))
    case .install(let change):
      print(skillsChangeText(change, removing: false))
      renderSkillsNote(change)
    case .uninstall(let change):
      print(skillsChangeText(change, removing: true))
      renderSkillsNote(change)
    case .path(let path):
      print(path.skill.path)
    }
  }

  static func skillsListText(_ payload: SkillsListPayload) -> String {
    guard !payload.skills.isEmpty else { return "No bundled skills found." }
    return payload.skills.map { skill in
      let audience =
        skill.audience == .workflow
        ? "[workflow — not installable]".yellow
        : "[user]".dim
      var lines = ["\(skill.id.bold)  \(skill.name)  \(audience)"]
      for target in skill.targets {
        let detected = target.detected ? "" : "  \("(target not detected)".dim)"
        let destination = target.destination.map { "  \("→ \($0)".dim)" } ?? ""
        lines.append(
          "  \(target.id.padding(toLength: 7, withPad: " ", startingAt: 0))  "
            + "\(skillsStatusLabel(target))  "
            + "\(target.path.dim)\(destination)\(detected)"
        )
      }
      return lines.joined(separator: "\n")
    }.joined(separator: "\n\n")
  }

  static func skillsChangeText(_ payload: SkillsChangePayload, removing: Bool) -> String {
    guard !payload.results.isEmpty else {
      return removing ? "Nothing to remove." : "Nothing to install."
    }
    return payload.results.map { result in
      let verb: String
      switch (removing, result.before) {
      case (true, .notInstalled): verb = skillsColumn("not installed").dim
      case (true, _): verb = skillsColumn("removed").green
      case (false, .installed): verb = skillsColumn("unchanged").dim
      case (false, .broken): verb = skillsColumn("repaired").green
      case (false, .installedDifferentSource): verb = skillsColumn("replaced").green
      case (false, .notInstalled): verb = skillsColumn("installed").green
      }
      return "\(verb)  \(result.skill.bold) → \(result.target)  \(result.path.dim)"
    }.joined(separator: "\n")
  }

  private static func renderSkillsNote(_ payload: SkillsChangePayload) {
    guard let note = payload.note else { return }
    FileHandle.standardError.write(Data("note: \(note)\n".utf8))
  }

  private static func skillsStatusLabel(_ target: SkillsCommandTargetStatus) -> String {
    switch target.status {
    case .installed: skillsColumn("installed").green
    case .notInstalled: skillsColumn("not installed").dim
    case .installedDifferentSource where target.destination != nil: skillsColumn("linked elsewhere").yellow
    case .installedDifferentSource: skillsColumn("real file or directory").yellow
    case .broken: skillsColumn("broken link").red
    }
  }

  /// Pads before coloring so ANSI escapes do not skew column alignment.
  private static func skillsColumn(_ text: String) -> String {
    text.padding(toLength: 28, withPad: " ", startingAt: 0)
  }

  private static func renderAgentsRead(_ payload: AgentReadCommandPayload) {
    if let data = agentReadResultOnlyData(payload) {
      FileHandle.standardOutput.write(data)
      return
    }
    print(agentReadSnapshotText(payload))
  }

  static func agentReadResultOnlyData(_ payload: AgentReadCommandPayload) -> Data? {
    guard payload.outputMode == .resultOnly, let text = payload.result.text else { return nil }
    return Data(text.utf8)
  }

  static func agentReadSnapshotText(_ payload: AgentReadCommandPayload) -> String {
    var lines = [
      "Agent: \(payload.agent.type)",
      "Status: \(payload.agent.status.rawValue)",
    ]
    if let reason = payload.agent.detectionReason {
      lines.append("Reason: \(reason)")
    }
    lines.append("Changed: \(payload.agent.lastChangedAt)")

    let result = payload.result
    if let error = result.error {
      lines.append("Result: \(result.state.rawValue) (\(error.code))")
    } else {
      lines.append("Result: \(result.state.rawValue)")
    }

    if let blocker = payload.blocker {
      lines.append("")
      lines.append("## Blocker")
      lines.append(blocker.text)
    }
    if let text = result.text {
      lines.append("")
      lines.append("## Latest result")
      lines.append(text)
    }
    return lines.joined(separator: "\n")
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

  private static func renderLifecycleWarnings(_ payload: LifecycleCommandPayload) {
    guard let warnings = payload.warnings else { return }
    for warning in warnings {
      let line = "warning: [\(warning.code.rawValue)] \(warning.runtime): \(warning.message)\n"
      FileHandle.standardError.write(Data(line.utf8))
    }
  }

  private static func renderLifecycle(_ payload: LifecycleCommandPayload, command: String) -> String {
    let wt = payload.target.worktree
    let tab = payload.target.tab
    let pane = payload.target.pane
    let projectName = projectName(from: wt.path)
    let verb = command == "create" ? "Created" : "Closed"

    switch payload.resource {
    case .tab:
      var lines = [
        "\(verb) tab \(projectName.cyan.bold)\(":".dim)\(wt.name) → \(tab.title.yellow)"
          + "  \(tab.id.dim)",
        "  \("pane:".dim) \(pane.title.green)  \(pane.id.dim)",
      ]
      if let launch = payload.launch {
        lines.append("  \("profile:".dim) \(launch.profileName)  \("agent:".dim) \(launch.agent)")
      }
      if let dispatch = payload.dispatch {
        lines.append("  \("dispatch:".dim) \(dispatch.id)")
      }
      return lines.joined(separator: "\n")
    case .pane:
      var lines = [
        "\(verb) pane \(projectName.cyan.bold)\(":".dim)\(wt.name) → \(pane.title.green)"
          + "  \(pane.id.dim)"
      ]
      if let anchor = payload.anchor, let direction = payload.direction {
        lines.append("  \("anchor:".dim) \(anchor.pane.id.dim)  \("direction:".dim) \(direction.rawValue)")
      }
      if let launch = payload.launch {
        lines.append("  \("profile:".dim) \(launch.profileName)  \("agent:".dim) \(launch.agent)")
      }
      if let dispatch = payload.dispatch {
        lines.append("  \("dispatch:".dim) \(dispatch.id)")
      }
      return lines.joined(separator: "\n")
    }
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
