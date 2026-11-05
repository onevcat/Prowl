import SwiftUI

/// An agent message rendered from its Markdown blocks.
struct MirrorMarkdownView: View {
  let blocks: [MirrorMarkdown.Block]

  init(text: String) {
    blocks = MirrorMarkdownCache.shared.blocks(for: text)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        BlockView(block: block)
      }
    }
    .textSelection(.enabled)
  }
}

private struct BlockView: View {
  let block: MirrorMarkdown.Block

  var body: some View {
    switch block {
    case .heading(let level, let text):
      MirrorInlineText(text).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
        .padding(.top, 2)
        .accessibilityAddTraits(.isHeader)
    case .paragraph(let text):
      MirrorInlineText(text)
    case .list(let items):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker(item.marker)
            MirrorInlineText(item.text)
          }
          .padding(.leading, CGFloat(item.depth) * 16)
        }
      }
    case .quote(let text):
      MirrorInlineText(text)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
          Capsule().fill(.tertiary).frame(width: 3)
        }
    case .code(_, let text):
      ScrollView(.horizontal, showsIndicators: false) {
        Text(text).font(.footnote.monospaced()).fixedSize(horizontal: true, vertical: false)
          .padding(10)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    case .table(let header, let rows):
      MirrorMarkdownTable(header: header, rows: rows)
    case .rule:
      Divider().padding(.vertical, 2)
    }
  }

  @ViewBuilder private func marker(_ marker: MirrorMarkdown.ListItem.Marker) -> some View {
    switch marker {
    case .bullet:
      Text("•").foregroundStyle(.secondary)
    case .ordered(let number):
      Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
    case .task(let done):
      Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .accessibilityLabel(done ? "Done" : "Not done")
    }
  }
}

private struct MirrorMarkdownTable: View {
  let header: [String]
  let rows: [[String]]

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
            MirrorInlineText(cell).font(.subheadline.weight(.semibold))
          }
        }
        .padding(.vertical, 8)
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          Divider().gridCellUnsizedAxes(.horizontal)
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
              MirrorInlineText(cell).font(.subheadline)
            }
          }
          .padding(.vertical, 8)
        }
      }
      .padding(.horizontal, 12)
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
  }
}

/// Inline Markdown (emphasis, code spans, links) in one `Text`; plain text when it does not parse.
struct MirrorInlineText: View {
  let attributed: AttributedString

  init(_ text: String) {
    attributed = MirrorMarkdownCache.shared.inline(for: text)
  }

  var body: some View {
    Text(attributed).fixedSize(horizontal: false, vertical: true)
  }
}

/// Parsing runs on every body evaluation of a long chat; the cache keeps it to once per text.
@MainActor final class MirrorMarkdownCache {
  static let shared = MirrorMarkdownCache()
  private let blockCache = NSCache<NSString, Box<[MirrorMarkdown.Block]>>()
  private let inlineCache = NSCache<NSString, Box<AttributedString>>()

  private init() {
    blockCache.countLimit = 400
    inlineCache.countLimit = 2000
  }

  func blocks(for text: String) -> [MirrorMarkdown.Block] {
    if let hit = blockCache.object(forKey: text as NSString) { return hit.value }
    let blocks = MirrorMarkdown.parse(text)
    blockCache.setObject(Box(blocks), forKey: text as NSString)
    return blocks
  }

  func inline(for text: String) -> AttributedString {
    if let hit = inlineCache.object(forKey: text as NSString) { return hit.value }
    var attributed =
      (try? AttributedString(
        markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
    inlineCache.setObject(Box(attributed), forKey: text as NSString)
    return attributed
  }

  private final class Box<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
  }
}
