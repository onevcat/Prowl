import ProwlCLIShared
import SwiftUI

struct WorkflowHistoryJSONView: View {
  let values: [String: WorkflowJSONValue]
  let worktree: URL
  let onOutput: (WorkflowHistoryOutputIntent) -> Void
  var title = "Output"

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Spacer()
        WorkflowHistoryIconButton(label: "Open full JSON \(title.lowercased())", symbol: "arrow.up.forward.square") {
          onOutput(.openJSON(values))
        }
        WorkflowHistoryIconButton(label: "Copy full JSON \(title.lowercased())", symbol: "doc.on.doc") {
          onOutput(.copyJSON(values))
        }
      }
      if values.isEmpty { Text("No fields").foregroundStyle(.secondary) }
      ForEach(WorkflowHistoryOutputField.fields(values)) { field in
        WorkflowHistoryOutputFieldView(field: field, worktree: worktree, onOutput: onOutput)
      }
      if values.count > 32 { Text("\(values.count - 32) more fields in full output").foregroundStyle(.secondary) }
    }
    .font(.caption)
  }
}

private struct WorkflowHistoryOutputFieldView: View {
  let field: WorkflowHistoryOutputField
  let worktree: URL
  let onOutput: (WorkflowHistoryOutputIntent) -> Void
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        if let children = field.children, !children.isEmpty {
          Button {
            expanded.toggle()
          } label: {
            HStack(spacing: 6) {
              Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption2).frame(width: 10).accessibilityHidden(true)
              valueRow
            }.contentShape(.rect)
          }
          .buttonStyle(.plain)
          .help("\(expanded ? "Collapse" : "Expand") \(field.key)")
          .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        } else {
          Color.clear.frame(width: 10, height: 1)
          valueRow
        }
        if let url = field.fileURL {
          WorkflowHistoryIconButton(label: "Open \(url.lastPathComponent)", symbol: "arrow.up.forward.square") {
            onOutput(.openArtifact(url, worktree: worktree))
          }
          WorkflowHistoryIconButton(label: "Reveal \(url.lastPathComponent) in Finder", symbol: "folder") {
            onOutput(.revealArtifact(url, worktree: worktree))
          }
        }
        if case .string(let value) = field.value {
          WorkflowHistoryIconButton(label: "Copy \(field.key)", symbol: "doc.on.doc") { onOutput(.copyText(value)) }
        }
      }
      if expanded, let children = field.children {
        ForEach(children) { child in
          WorkflowHistoryOutputFieldView(field: child, worktree: worktree, onOutput: onOutput)
        }
        .padding(.leading, 14)
        if field.childCount > children.count {
          Text("\(field.childCount - children.count) more fields in full output")
            .foregroundStyle(.secondary).padding(.leading, 30)
        }
      }
    }
  }

  private var valueRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(field.displayKey)
        .foregroundStyle(.secondary)
        .frame(width: 100, alignment: .leading)
        .help(
          field.key == "output_path"
            ? "The saved JSON result file; output contains its fields" : String(field.key.prefix(300)))
      Text(field.fileURL?.path ?? field.summary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.caption.monospaced())
    .lineLimit(1)
    .truncationMode(.middle)
  }
}

struct WorkflowHistoryDeliveryView: View {
  let delivery: WorkflowDeliveryRecord
  let directory: URL
  let onOutput: (WorkflowHistoryOutputIntent) -> Void
  var revision = WorkflowHistoryFileRevision()

  var body: some View {
    if WorkflowSchema.isSlug(delivery.name), delivery.ordinal > 0 {
      let url = delivery.path.hasPrefix("/") ? URL(filePath: delivery.path) : directory.appending(path: delivery.path)
      WorkflowHistoryTextFileView(
        label: delivery.name, contentName: "output", url: url, onOutput: onOutput,
        verdict: delivery.verdict, revision: revision)
    } else {
      Text("Output reference is invalid.").foregroundStyle(.secondary)
    }
  }
}

struct WorkflowHistoryTextFileView: View {
  let label: String
  let contentName: String
  let url: URL
  let onOutput: (WorkflowHistoryOutputIntent) -> Void
  var verdict: String?
  var revision = WorkflowHistoryFileRevision()
  @State private var preview: WorkflowHistoryTextPreview?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if let verdict { Text(verdict).font(.caption.weight(.medium)).lineLimit(1) }
        Spacer(minLength: 8)
        HStack(spacing: 8) {
          WorkflowHistoryIconButton(label: "Open full \(contentName)", symbol: "arrow.up.forward.square") {
            onOutput(.openFile(url))
          }
          WorkflowHistoryIconButton(label: "Copy full \(contentName)", symbol: "doc.on.doc") {
            onOutput(.copyFile(url))
          }
          WorkflowHistoryIconButton(label: "Reveal \(contentName) in Finder", symbol: "folder") {
            onOutput(.reveal(url))
          }
        }
      }
      if let preview {
        WorkflowHistoryMarkdownPreview(preview: preview, emptyText: "Empty \(contentName)")
      } else {
        Text(error ?? "Loading \(contentName)…").foregroundStyle(.secondary)
      }
    }
    .task(id: WorkflowHistoryFileLoadKey(url: url, revision: revision)) {
      preview = nil
      error = nil
      let storage = WorkflowHistoryStorage.configured
      let outputURL = url
      let result = await Task.detached(priority: .utility) { () -> WorkflowHistoryTextPreview? in
        try? WorkflowHistoryTextPreview.read(outputURL, storage: storage)
      }.value
      guard !Task.isCancelled else { return }
      preview = result
      if result == nil { error = "Preview unavailable. Open the file to view its contents." }
    }
  }
}
