import ProwlCLIShared
import SwiftUI

struct WorkflowHistoryStepRow: View {
  let group: WorkflowHistoryStepGroup
  let duration: TimeInterval?
  let directory: URL?
  let worktree: URL
  let livePaneIDs: Set<UUID>
  let updatedAt: Date
  let onFocus: (UUID) -> Void
  let onOutput: (WorkflowHistoryOutputIntent) -> Void
  let onInteraction: () -> Void
  @State private var expanded: Bool

  init(
    group: WorkflowHistoryStepGroup, duration: TimeInterval?, directory: URL?, worktree: URL,
    livePaneIDs: Set<UUID>, updatedAt: Date, onFocus: @escaping (UUID) -> Void,
    onOutput: @escaping (WorkflowHistoryOutputIntent) -> Void, onInteraction: @escaping () -> Void
  ) {
    self.group = group
    self.duration = duration
    self.directory = directory
    self.worktree = worktree
    self.livePaneIDs = livePaneIDs
    self.updatedAt = updatedAt
    self.onFocus = onFocus
    self.onOutput = onOutput
    self.onInteraction = onInteraction
    _expanded = State(initialValue: group.state == "failed" || group.state == "needs_attention")
  }

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        if group.attempts.isEmpty {
          Text("This step did not run.").foregroundStyle(.secondary)
        }
        ForEach(Array(group.attempts.enumerated()), id: \.offset) { index, attempt in
          if group.attempts.count > 1 {
            if index == group.attempts.count - 1 {
              Text("\(group.attemptLabel) \(index + 1)").font(.caption).foregroundStyle(.secondary)
              attemptContent(attempt)
            } else {
              DisclosureGroup(
                "\(group.attemptLabel) \(index + 1) · \(WorkflowHistoryStatus.label(attempt.state.rawValue))"
              ) {
                attemptContent(attempt)
              }.disclosureGroupStyle(.automatic)
            }
          } else {
            attemptContent(attempt)
          }
        }
      }
      .font(.callout)
      .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        WorkflowHistoryStatusIcon(state: group.state)
        VStack(alignment: .leading, spacing: 3) {
          Text(group.title).lineLimit(2)
          if !group.contextLabel.isEmpty {
            Text(group.contextLabel).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
        Spacer(minLength: 8)
        Text(duration.map(WorkflowHistoryTiming.duration) ?? "—")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          .fixedSize()
          .help(duration == nil ? "No duration recorded" : "Recorded step duration, including retries")
      }.font(.subheadline)
    }
    .disclosureGroupStyle(WorkflowHistoryDisclosureStyle())
    .onChange(of: expanded) { _, _ in onInteraction() }
  }

  @ViewBuilder
  private func attemptContent(_ attempt: WorkflowRunRecord.Step) -> some View {
    let revision = WorkflowHistoryFileRevision(
      updatedAt: attempt.state == .active ? updatedAt : nil, state: attempt.state.rawValue)
    if let error = attempt.error {
      HStack {
        Text(attempt.state == .completed ? "Earlier issue" : "Error").font(.caption).foregroundStyle(.secondary)
        Spacer()
        WorkflowHistoryIconButton(label: "Open full error", symbol: "arrow.up.forward.square") {
          onOutput(.openText(error, "error.txt"))
        }
        WorkflowHistoryIconButton(label: "Copy full error", symbol: "doc.on.doc") {
          onOutput(.copyText(error))
        }
      }
      Text(String(error.prefix(1000))).foregroundStyle(.orange).textSelection(.enabled).lineLimit(6)
    }
    if attempt.state == .skipped {
      Text(attempt.branchExcluded == true ? "This branch was not selected." : "This step was skipped.")
        .font(.caption).foregroundStyle(.secondary)
    }
    WorkflowHistoryExecutionView(
      definition: group.definition, attempt: attempt,
      invocation: attempt.ordinal.flatMap { group.invocations[$0] }, directory: directory,
      worktree: worktree, livePaneIDs: livePaneIDs, revision: revision, onFocus: onFocus, onOutput: onOutput)
    if let submissions = attempt.submissions, !submissions.isEmpty, let directory {
      ForEach(Array(submissions.enumerated()), id: \.offset) { index, submission in
        if index == submissions.count - 1 {
          if submissions.count > 1 || !submission.accepted {
            Text("Submission \(index + 1) · \(submission.statusLabel)").font(.caption).foregroundStyle(.secondary)
          }
          ForEach(submission.issues, id: \.self) { Text($0).foregroundStyle(.orange).lineLimit(3) }
          WorkflowHistoryDeliveryView(
            delivery: submission.delivery, directory: directory, onOutput: onOutput, revision: revision)
        } else {
          DisclosureGroup("Submission \(index + 1) · \(submission.statusLabel)") {
            ForEach(submission.issues, id: \.self) { Text($0).foregroundStyle(.orange).lineLimit(3) }
            WorkflowHistoryDeliveryView(
              delivery: submission.delivery, directory: directory, onOutput: onOutput, revision: revision)
          }.disclosureGroupStyle(.automatic)
        }
      }
    } else if let delivery = attempt.delivery, let directory {
      WorkflowHistoryDeliveryView(delivery: delivery, directory: directory, onOutput: onOutput, revision: revision)
    }
    if let outputs = attempt.outputs, !outputs.isEmpty {
      WorkflowHistoryJSONView(values: outputs, worktree: worktree, onOutput: onOutput)
    }
    if let directory, let diagnostics = WorkflowHistoryTiming.diagnosticDirectory(attempt, directory: directory) {
      Menu {
        ForEach(["stdout.log", "stderr.log", "execution.json"], id: \.self) { name in
          Button(name, systemImage: "doc.text") { onOutput(.openFile(diagnostics.appending(path: name))) }
            .help("Open \(name)")
        }
      } label: {
        Label("Diagnostics", systemImage: "terminal")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Open action logs or the execution record")
    }
  }
}
