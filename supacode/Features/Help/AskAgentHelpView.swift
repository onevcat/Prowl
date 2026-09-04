import AppKit
import SwiftUI

/// A small, self-contained help sheet that hands the user a ready-to-paste
/// prompt for their AI agent. The prompt points the agent at the documentation
/// bundled inside the app (`Contents/Resources/docs`). Localized to the device
/// language; purely presentational (no store).
struct AskAgentHelpView: View {
  private let strings: AskAgentHelpStrings
  private let onDone: () -> Void
  @State private var didCopy = false

  init(
    docsDirectoryPath: String = AskAgentHelpView.resolvedDocsDirectoryPath,
    locale: Locale = AskAgentHelpPrompt.systemPreferredLocale(),
    onDone: @escaping () -> Void
  ) {
    self.init(
      strings: AskAgentHelpPrompt.strings(docsDirectoryPath: docsDirectoryPath, locale: locale), onDone: onDone)
  }

  /// The same sheet over any prompt (Settings › Workflows › "Ask an Agent…").
  init(strings: AskAgentHelpStrings, onDone: @escaping () -> Void) {
    self.strings = strings
    self.onDone = onDone
  }

  /// The bundled docs directory, falling back to the standard install path so
  /// the prompt always shows a sensible location even if the bundle lookup fails.
  static var resolvedDocsDirectoryPath: String {
    SupacodePaths.bundledDocsDirectoryPath ?? "/Applications/Prowl.app/Contents/Resources/docs"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(strings.title, systemImage: "sparkles")
        .font(.headline)

      Text(strings.explanation)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      ScrollView {
        Text(strings.prompt)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .frame(minHeight: 200, maxHeight: 300)
      .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(.separator, lineWidth: 1)
      )

      HStack {
        Button {
          copyPrompt()
        } label: {
          Label(
            didCopy ? strings.copiedButtonTitle : strings.copyButtonTitle,
            systemImage: didCopy ? "checkmark" : "doc.on.doc"
          )
        }
        .buttonStyle(.borderedProminent)

        Spacer()

        Button(strings.doneButtonTitle) {
          onDone()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 540)
  }

  private func copyPrompt() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(strings.prompt, forType: .string)
    didCopy = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      didCopy = false
    }
  }
}
