import SwiftUI

struct MirrorDocumentView: View {
  /// The coordinate space of the row tops. Apply it to the scroll content.
  nonisolated static var rowSpace: NamedCoordinateSpace { .named("MirrorDocumentView.rows") }

  let text: String
  /// Receives the top of each row in `rowSpace` when the row is laid out, and nil when it leaves
  /// the layout.
  var onRowTop: ((MirrorDocument.Row.ID, CGFloat?) -> Void)?
  @State private var expanded: MirrorDocument.Block?

  var body: some View {
    // One flat lazy stack: each chunk of a long text block is a row, so a reading position can
    // anchor to the text near the top of the visible area.
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(MirrorDocument(text).rows) { row in
        rowContent(row)
          .padding(.top, row.id.chunk == 0 && row.id.block > 0 ? 12 : 0)
          .id(row.id)
          .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: Self.rowSpace).minY
          } action: { top in
            onRowTop?(row.id, top)
          }
          .onDisappear { onRowTop?(row.id, nil) }
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

  @ViewBuilder
  private func rowContent(_ row: MirrorDocument.Row) -> some View {
    let block = row.block
    switch block {
    case .text(_, let content):
      if let chunk = row.chunk {
        Text(verbatim: chunk.display)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contextMenu {
            Button("Copy Full Text Block") { UIPasteboard.general.string = content }
          }
      } else {
        Text(renderInline(content)).textSelection(.enabled)
      }
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

  private func renderInline(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
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
