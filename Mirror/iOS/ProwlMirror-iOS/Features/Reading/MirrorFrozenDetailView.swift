import SwiftUI

struct MirrorFrozenDetailView: View {
  let block: MirrorDocument.Block
  @ScaledMetric(relativeTo: .body) private var columnWidth = 220

  var body: some View {
    if case .table(_, _, let rows) = block {
      ScrollView([.horizontal, .vertical]) {
        LazyVGrid(
          columns: Array(
            repeating: GridItem(.fixed(columnWidth), alignment: .topLeading),
            count: rows.first?.count ?? 0),
          alignment: .leading, spacing: 12
        ) {
          ForEach(0..<(rows.count * (rows.first?.count ?? 0)), id: \.self) { index in
            let columnCount = rows.first?.count ?? 1
            Text(verbatim: rows[index / columnCount][index % columnCount])
              .fontWeight(index < columnCount ? .semibold : .regular)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding()
      }
      .accessibilityIdentifier("mirror-frozen-table")
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(MirrorTextLayout.chunks(block.raw)) { chunk in
            Text(verbatim: chunk.display)
              .font(.body.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding()
      }
    }
  }
}
