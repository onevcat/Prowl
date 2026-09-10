import ProwlCLIShared
import SwiftUI

struct WorkflowHistoryExecutionView: View {
  let definition: WorkflowHistoryStepDefinition
  let attempt: WorkflowRunRecord.Step
  let invocation: WorkflowRunRecordInvocation?
  let directory: URL?
  let worktree: URL
  let livePaneIDs: Set<UUID>
  let revision: WorkflowHistoryFileRevision
  let onFocus: (UUID) -> Void
  let onOutput: (WorkflowHistoryOutputIntent) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let invocation {
        if let target = invocation.target {
          WorkflowHistoryRoleView(
            role: invocation.role, binding: target, livePaneIDs: livePaneIDs, showsName: true, onFocus: onFocus)
        }
        if let status = WorkflowHistoryExecution.agentStatus(invocation) {
          Text(status).font(.caption).foregroundStyle(.secondary)
        }
        if let directory, let url = WorkflowHistoryExecution.promptURL(invocation, directory: directory) {
          WorkflowHistoryTextFileView(
            label: "Prompt", contentName: "prompt", url: url, onOutput: onOutput, revision: revision)
        }
      }
      if let action = definition.actionID {
        LabeledContent("Action", value: action).font(.caption).textSelection(.enabled)
        if let directory, let execution = WorkflowHistoryTiming.diagnosticDirectory(attempt, directory: directory) {
          WorkflowHistoryActionInputView(
            directory: execution, worktree: worktree, onOutput: onOutput, revision: revision)
        }
      }
      if let summary = attempt.summary {
        if definition.kind == "notify" {
          Text("Sent to Prowl Notifications").font(.caption).foregroundStyle(.secondary)
          WorkflowHistoryInlineTextView(text: summary, name: "notification", onOutput: onOutput)
        } else {
          Text(summary).font(.caption).textSelection(.enabled)
        }
      }
    }
  }
}

struct WorkflowHistoryRoleView: View {
  let role: String
  let binding: WorkflowRunRecord.Binding
  let livePaneIDs: Set<UUID>
  var showsName = false
  let onFocus: (UUID) -> Void
  @ScaledMetric(relativeTo: .caption) private var iconSize = 13

  var body: some View {
    let presentation = WorkflowHistoryRole(role: role, binding: binding, livePaneIDs: livePaneIDs)
    HStack(spacing: 5) {
      Text("\(role):").foregroundStyle(.secondary)
      if let agent = presentation.agent {
        let token = DetectedAgent(rawValue: agent)?.iconLookupToken ?? agent
        TabIconImage(
          rawName: (CommandIconMap.iconForFirstToken(token) ?? TabIconSource(systemSymbol: "terminal")).storageString,
          pointSize: iconSize
        ).accessibilityLabel(agent).help(agent)
      }
      if showsName, let name = binding.profile?.name ?? binding.pane?.displayName {
        Text(name).lineLimit(1).truncationMode(.middle).help(name)
      }
      if let pane = presentation.livePane {
        Button("@\(pane.handle)") { onFocus(pane.surfaceID) }
          .buttonStyle(.link).help("Focus \(role) in @\(pane.handle)")
      } else if presentation.agent == nil {
        Text("Not bound").foregroundStyle(.secondary)
      }
    }.font(.caption)
  }
}

private struct WorkflowHistoryActionInputView: View {
  let directory: URL
  let worktree: URL
  let onOutput: (WorkflowHistoryOutputIntent) -> Void
  let revision: WorkflowHistoryFileRevision
  @State private var inputs: [String: WorkflowJSONValue]?
  @State private var unavailable = false

  var body: some View {
    Group {
      if let inputs {
        WorkflowHistoryJSONView(values: inputs, worktree: worktree, onOutput: onOutput, title: "Input")
      } else {
        Text(unavailable ? "No saved action input." : "Loading input…").font(.caption).foregroundStyle(.secondary)
      }
    }
    .task(id: WorkflowHistoryFileLoadKey(url: directory, revision: revision)) {
      inputs = nil
      unavailable = false
      let storage = WorkflowHistoryStorage.configured
      let url = directory.appending(path: "request.json")
      let result = await Task.detached(priority: .utility) {
        guard let data = try? storage.read(url, limit: WorkflowSizeLimits.transportFrame) else {
          return nil as [String: WorkflowJSONValue]?
        }
        return try? WorkflowHistoryExecution.actionInput(data)
      }.value
      guard !Task.isCancelled else { return }
      inputs = result
      unavailable = result == nil
    }
  }
}

private struct WorkflowHistoryInlineTextView: View {
  let text: String
  let name: String
  let onOutput: (WorkflowHistoryOutputIntent) -> Void

  var body: some View {
    let preview = WorkflowHistoryTextPreview(text)
    HStack(alignment: .top) {
      WorkflowHistoryMarkdownPreview(preview: preview, emptyText: "Empty message")
      WorkflowHistoryIconButton(label: "Open full \(name)", symbol: "arrow.up.forward.square") {
        onOutput(.openText(text, "\(name).md"))
      }
      WorkflowHistoryIconButton(label: "Copy full \(name)", symbol: "doc.on.doc") {
        onOutput(.copyText(text))
      }
    }
  }
}
