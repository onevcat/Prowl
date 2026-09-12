import SwiftUI

struct MirrorDocumentView: View {
  let text: String
  @State private var expanded: MirrorDocument.Block?

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 12) {
      ForEach(MirrorDocument(text).blocks) { block in
        switch block {
        case .text(_, let content):
          textBlock(content)
        case .code(_, let language, let code):
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(language.isEmpty ? "Code" : language).font(.caption).foregroundStyle(.secondary)
              Spacer()
              Button("Expand") { expanded = block }
            }
            Text(code).font(.body.monospaced()).lineLimit(6).textSelection(.enabled)
          }
          .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        case .table(_, _, let rows):
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Table · \(rows.count - 1) rows").font(.caption).foregroundStyle(.secondary)
              Spacer()
              Button("Expand") { expanded = block }
            }
            ScrollView(.horizontal) { table(Array(rows.prefix(5))) }
          }
          .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
      }
    }
    .sheet(item: $expanded) { block in
      NavigationStack {
        MirrorFrozenDetailView(block: block)
          .navigationTitle("Frozen detail")
          .toolbar {
            Button("Copy") { UIPasteboard.general.string = block.raw }
            Button("Done") { expanded = nil }
          }
      }
    }
  }

  private func renderInline(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }

  @ViewBuilder
  private func textBlock(_ content: String) -> some View {
    let chunks = MirrorTextLayout.chunks(content)
    if chunks.count == 1 {
      Text(renderInline(content)).textSelection(.enabled)
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(chunks) { chunk in
          Text(verbatim: chunk.display)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .contextMenu {
        Button("Copy Full Text Block") { UIPasteboard.general.string = content }
      }
    }
  }

  private func table(_ rows: [[String]]) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
      ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
        GridRow {
          ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
            Text(cell).fontWeight(index == 0 ? .semibold : .regular).textSelection(.enabled)
          }
        }
        if index == 0 { Divider() }
      }
    }
  }
}
