import ComposableArchitecture
import ProwlCLIShared
import SwiftUI

struct WorkflowStepHistoryDetailView: View {
  let record: WorkflowRunRecord
  let directory: URL?
  let livePaneIDs: Set<UUID>
  let liveRun: WorkflowRun?
  let onIntent: (WorkflowRunPanelIntent) -> Void
  let onOutput: (WorkflowHistoryOutputIntent) -> Void
  var onInteraction: () -> Void = {}
  @State private var pendingControl: WorkflowAttentionControl?
  @State private var confirmsControl = false
  @State private var groups: [WorkflowHistoryStepGroup] = []
  @State private var durations: [String: TimeInterval] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if !record.bindings.isEmpty { roles }
      if record.historyIsPartial == true {
        Text("Some control history was omitted after 10,000 records. Recorded outputs remain available.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(groups) { group in
            WorkflowHistoryStepRow(
              group: group, duration: durations[group.id], directory: directory, worktree: record.worktree.rootURL,
              livePaneIDs: livePaneIDs, updatedAt: record.run.updatedAt,
              onFocus: { surfaceID in
                onInteraction()
                onIntent(.focusPane(worktreeID: record.worktree.id, surfaceID: surfaceID))
              },
              onOutput: onOutput, onInteraction: onInteraction)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let run = liveRun, run.status.attention != nil { attentionControls(run) }
      Divider()
      footer
    }
    .task(id: HistoryProjectionKey(record: record)) {
      let snapshot = record
      let directory = directory
      let storage = WorkflowHistoryStorage.configured
      let result = await Task.detached(priority: .userInitiated) {
        let groups = WorkflowHistoryStepGroup.groups(snapshot)
        return (
          groups, WorkflowHistoryTiming.durations(groups, record: snapshot, directory: directory, storage: storage)
        )
      }.value
      if !Task.isCancelled {
        groups = result.0
        durations = result.1
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .confirmationDialog("Confirm Workflow Action", isPresented: $confirmsControl, presenting: pendingControl) {
      control in
      if let run = liveRun, let intent = control.intent(runID: run.id, worktreeID: run.context.worktree.id) {
        Button(control.label, role: control.isDestructive ? .destructive : nil) { onIntent(intent) }
      }
    } message: { control in
      Text(control.confirmationMessage ?? control.label)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(record.run.workflowName).font(.headline).lineLimit(2)
        Spacer(minLength: 0)
        Text(WorkflowHistoryStatus.label(record.run.status.state))
          .font(.subheadline).foregroundStyle(WorkflowHistoryStatus.tint(record.run.status.state))
          .fixedSize()
      }
      if record.run.status.isTerminal {
        timingLine(at: record.run.finishedAt ?? record.run.updatedAt)
      } else {
        TimelineView(.periodic(from: .now, by: 1)) { timingLine(at: $0.date) }
      }
    }
  }

  private func timingLine(at date: Date) -> some View {
    let duration = WorkflowHistoryTiming.duration(date.timeIntervalSince(record.run.startedAt))
    let elapsed = record.run.status.isTerminal ? "Finished in \(duration)" : "Running for \(duration)"
    return Label("\(WorkflowHistoryTiming.timestamp(record.run.startedAt)) · \(elapsed)", systemImage: "clock")
      .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      .lineLimit(1)
      .help("Started \(WorkflowHistoryTiming.timestamp(record.run.startedAt)) · \(elapsed)")
  }

  private var roles: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 16) {
        ForEach(record.bindings.keys.sorted(), id: \.self) { role in
          if let binding = record.bindings[role] {
            WorkflowHistoryRoleView(role: role, binding: binding, livePaneIDs: livePaneIDs) { surfaceID in
              onInteraction()
              onIntent(.focusPane(worktreeID: record.worktree.id, surfaceID: surfaceID))
            }
          }
        }
      }
      .font(.caption)
    }.scrollIndicators(.never)
  }

  private func attentionControls(_ run: WorkflowRun) -> some View {
    let presentation = WorkflowRunPresentation(run: run, now: Date())
    return VStack(alignment: .leading, spacing: 8) {
      if let attention = run.status.attention {
        Text(attention.message).font(.callout).foregroundStyle(.orange).lineLimit(4)
      }
      ViewThatFits {
        controls(presentation, run: run)
        ScrollView(.horizontal) { controls(presentation, run: run) }
      }
    }
  }

  private func controls(_ presentation: WorkflowRunPresentation, run: WorkflowRun) -> some View {
    HStack {
      ForEach(presentation.attentionControls) { control in
        if control.action == .acceptWithVerdict {
          Menu(control.label) {
            ForEach(control.verdicts, id: \.self) { verdict in
              Button(verdict) {
                if let intent = control.intent(runID: run.id, worktreeID: run.context.worktree.id, verdict: verdict) {
                  onIntent(intent)
                }
              }
            }
          }.help(control.label)
        } else {
          Button(control.label) {
            onInteraction()
            if control.confirmationMessage != nil {
              pendingControl = control
              confirmsControl = true
            } else if let intent = control.intent(runID: run.id, worktreeID: run.context.worktree.id) {
              onIntent(intent)
            }
          }
          .disabled(control.intent(runID: run.id, worktreeID: run.context.worktree.id) == nil)
          .help(control.label)
        }
      }
    }.controlSize(.small)
  }

  private var footer: some View {
    HStack {
      if let directory {
        WorkflowHistoryIconButton(label: "Reveal run in Finder", symbol: "folder") {
          onIntent(.revealRunFolder(directory))
        }
        WorkflowHistoryIconButton(label: "Open workflow log", symbol: "doc.text") {
          onOutput(.openFile(directory.appending(path: "log.md")))
        }
        Spacer()
        Menu {
          Button("Keep Run") { onOutput(.keep(directory)) }.help("Protect this run from cleanup")
          Button("Export…") { onOutput(.export(directory)) }
            .disabled(!record.run.status.isTerminal).help("Export this finished run as a ZIP")
          if let run = liveRun, !run.status.isTerminal {
            Button("Cancel Run", role: .destructive) {
              onInteraction()
              pendingControl = WorkflowAttentionControl(
                action: .cancel, run: run,
                attention: WorkflowAttention(
                  reason: .blocked, stepID: "", role: nil, ordinal: nil,
                  actions: [.cancel], message: ""), skipConsequence: .noDelivery)
              confirmsControl = true
            }
          }
        } label: {
          Image(systemName: "ellipsis").accessibilityLabel("More run actions")
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More run actions")
      }
    }.controlSize(.small)
  }
}

// A constant hash keeps the full record comparison out of hashing large JSON bodies.
private struct HistoryProjectionKey: Hashable {
  let record: WorkflowRunRecord
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.record == rhs.record }
  func hash(into hasher: inout Hasher) { hasher.combine(record.run.id) }
}
