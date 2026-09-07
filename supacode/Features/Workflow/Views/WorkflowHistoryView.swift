import ComposableArchitecture
import ProwlCLIShared
import SwiftUI

struct WorkflowHistoryView: View {
  @Bindable var store: StoreOf<WorkflowHistoryFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Workflow History").font(.title2.bold())
        Spacer()
        if store.isBusy { ProgressView().controlSize(.small) }
        Button("Refresh", systemImage: "arrow.clockwise") { store.send(.refresh) }
          .help("Refresh history and storage usage")
          .disabled(store.isBusy)
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .help("Close workflow history (Esc)")
      }
      Text("\(size(store.preview.totalBytes)) used · 5 GiB soft budget")
        .font(.headline)
      Text(
        "Runs expire 30 days after completion. To meet the budget, older runs may expire after 24 hours. "
          + "Keep Run prevents cleanup. Outputs and action artifacts expire with their run; "
          + "export a ZIP for durable results."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if !store.preview.issues.isEmpty {
        Text("Some history could not be scanned. Usage is a lower estimate; those locations are preserved.")
          .foregroundStyle(.secondary)
          .help(store.preview.issues.joined(separator: "\n"))
      }
      if store.preview.overBudget {
        Label("Protected runs prevent reaching the budget. No active data will be removed.", systemImage: "info.circle")
          .foregroundStyle(.secondary)
      }
      if let error = store.error {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red).textSelection(.enabled)
      }
      if let result = store.result {
        Text(result).foregroundStyle(.secondary).textSelection(.enabled)
      }
      TextField("Filter by workflow, execution root, or run UUID", text: $store.query.sending(\.setQuery))
        .textFieldStyle(.roundedBorder)
      List(store.entries, id: \.directory) { entry in
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.name).font(.headline)
            Text(entry.root).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("\(entry.state) · \(size(entry.bytes)) · \(entry.id.uuidString)")
              .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let finished = entry.finishedAt {
              Text("Finished \(finished.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            }
            if let protection = entry.protection {
              Text(protection).font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          Toggle(
            "Keep Run",
            isOn: Binding(
              get: { entry.pinned }, set: { store.send(.keep(entry.directory, $0)) })
          )
          .toggleStyle(.checkbox)
          .help("Protect this run and its artifacts from automatic and manual cleanup")
          .disabled(store.isBusy || entry.state == "unknown")
          Button("Export…") { store.send(.export(entry.directory)) }
            .help("Export the complete finished run as an independent ZIP")
            .disabled(store.isBusy || !canExport(entry))
        }
        .padding(.vertical, 6)
      }
      .overlay {
        if store.entries.isEmpty && !store.isBusy {
          ContentUnavailableView(
            "No Workflow History", systemImage: "clock",
            description: Text(
              store.query.isEmpty
                ? "Completed and active runs appear here across all execution roots." : "No matching runs."))
        }
      }
      HStack {
        Text("\(store.preview.protectedEntries.count) protected run(s)")
          .foregroundStyle(.secondary)
        Spacer()
        Button("Preview Cleanup…") { store.send(.previewCleanup) }
          .help("Review eligible runs and estimated reclaimed space before deleting")
          .disabled(store.isBusy || store.preview.candidates.isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 620)
    .task { store.send(.refresh) }
    .sheet(
      isPresented: Binding(
        get: { store.confirmation != nil }, set: { if !$0 { store.send(.dismissCleanup) } })
    ) {
      if let preview = store.confirmation { cleanupPreview(preview) }
    }
  }

  private func cleanupPreview(_ preview: WorkflowHistoryPreview) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Clean Up Workflow History?").font(.title2.bold())
      Text(
        "Remove \(preview.candidates.count) complete run(s), including deliveries and action artifacts. "
          + "Estimated space: \(size(preview.reclaimedBytes)). This cannot be undone.")
      List(preview.candidates) { entry in
        VStack(alignment: .leading) {
          Text("\(entry.name) · \(size(entry.bytes))")
          Text(entry.root).font(.caption).foregroundStyle(.secondary)
          Text(entry.id.uuidString).font(.caption).foregroundStyle(.secondary)
        }
      }
      Text(
        "Keep Run, active runs, and the 24-hour diagnostic window remain protected. "
          + "Eligibility is checked again before deletion."
      )
      .font(.callout).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { store.send(.dismissCleanup) }
          .keyboardShortcut(.cancelAction).help("Cancel cleanup (Esc)")
        Button("Delete Runs", role: .destructive) { store.send(.confirmCleanup) }
          .help("Permanently delete only the eligible runs shown above")
      }
    }
    .padding(20)
    .frame(width: 620, height: 440)
  }

  private func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
  }

  private func canExport(_ entry: WorkflowHistoryEntry) -> Bool {
    entry.finishedAt != nil
      && ["completed", "cancelled", "skipped", "iteration_limit_reached", "interrupted"].contains(entry.state)
  }
}
