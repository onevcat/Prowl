import SwiftUI

struct WorkflowHistoryMarkdownPreview: View {
  let preview: WorkflowHistoryTextPreview
  let emptyText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(markdown)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if preview.remainingCharacters > 0 {
        Text("\(preview.remainingCharacters.formatted()) more characters…")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var markdown: AttributedString {
    let text = preview.text.isEmpty ? emptyText : preview.text
    return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}
