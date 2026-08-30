import AppKit
import SwiftUI

struct TabIconPickerView: View {
  let initialIcon: String?
  let defaultIcon: TabIconSource
  let title: String
  let subtitle: String
  let resetHelp: String
  let presets: [String]
  /// Optional host-provided section rendered between the header and
  /// the symbol field — the repository picker injects its
  /// "Suggested for this repository" content here. Receives a binding
  /// to the symbol name so tapping a suggestion fills the field.
  /// Type-erased because a generic parameter would forbid this type's
  /// static preset table.
  let suggestionsSection: ((Binding<String>) -> AnyView)?
  let onApply: (String?) -> Void
  let onCancel: () -> Void

  @State private var symbolName: String
  @FocusState private var symbolFieldFocused: Bool

  init(
    initialIcon: String?,
    defaultIcon: TabIconSource,
    title: String = "Tab Icon",
    subtitle: String = "Pick a preset or enter any SF Symbol name available in your system.",
    resetHelp: String = "Restore the default icon for this tab",
    presets: [String] = TabIconPickerView.symbolPresets,
    suggestionsSection: ((Binding<String>) -> AnyView)? = nil,
    onApply: @escaping (String?) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.initialIcon = initialIcon
    self.defaultIcon = defaultIcon
    self.title = title
    self.subtitle = subtitle
    self.resetHelp = resetHelp
    self.presets = presets
    self.suggestionsSection = suggestionsSection
    self.onApply = onApply
    self.onCancel = onCancel
    _symbolName = State(initialValue: initialIcon ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .interfaceFont(.headline)
        Text(subtitle)
          .interfaceFont(.caption)
          .foregroundStyle(.secondary)
      }

      if let suggestionsSection {
        suggestionsSection($symbolName)
      }

      HStack(spacing: 10) {
        TabIconImage(rawName: previewIcon.storageString, pointSize: 20)
          .foregroundStyle(isPreviewValid ? Color.primary : Color.secondary)
          .frame(width: 32, height: 32)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color.secondary.opacity(0.15))
          )
          .accessibilityLabel(Text("Preview"))
        TextField("SF Symbol name", text: $symbolName)
          .textFieldStyle(.roundedBorder)
          .focused($symbolFieldFocused)
          .onSubmit { applyIfValid() }
        Button("Open SF Symbols") {
          openSFSymbolsReference()
        }
      }

      LazyVGrid(
        columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 8),
        spacing: 6
      ) {
        ForEach(presets, id: \.self) { symbol in
          Button {
            symbolName = symbol
            symbolFieldFocused = true
          } label: {
            Image(systemName: symbol)
              .imageScale(.medium)
              .frame(width: 32, height: 32)
              .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .stroke(symbolName == symbol ? Color.accentColor : Color.clear, lineWidth: 2)
              )
              .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
              .accessibilityHidden(true)
          }
          .buttonStyle(.plain)
          .help(symbol)
        }
      }
      .padding(8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.secondary.opacity(0.08))
      )

      HStack {
        Button("Reset to Default") {
          onApply(nil)
        }
        .help(resetHelp)
        Spacer()
        Button("Cancel", role: .cancel) {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        Button("Done") {
          applyIfValid()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canApply)
      }
    }
    .padding(24)
    .frame(width: 410)
    .onAppear {
      symbolFieldFocused = true
    }
  }

  private var trimmedName: String {
    symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var previewIcon: TabIconSource {
    isPreviewValid ? TabIconSource(systemSymbol: trimmedName) : defaultIcon
  }

  private var isPreviewValid: Bool {
    Self.isValidSymbol(trimmedName)
  }

  private var canApply: Bool {
    !trimmedName.isEmpty && isPreviewValid
  }

  private func applyIfValid() {
    guard canApply else { return }
    onApply(trimmedName)
  }

  private func openSFSymbolsReference() {
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.SFSymbols") {
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
      return
    }
    guard let url = URL(string: "https://developer.apple.com/sf-symbols/") else { return }
    NSWorkspace.shared.open(url)
  }

  static func isValidSymbol(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
  }

  /// Presets curated around common development workflows. Grouped loosely by
  /// theme so scanning the grid reveals an intent quickly:
  /// terminal → run/build → watch/refresh → server/network → source control →
  /// code/files → tests/bugs → AI/agent → release/deploy → metrics/logs →
  /// security → compute.
  static let symbolPresets: [String] = [
    "terminal",
    "terminal.fill",
    "play.fill",
    "stop.fill",
    "hammer.fill",
    "wrench.and.screwdriver.fill",
    "eye.fill",
    "clock.fill",
    "arrow.clockwise",
    "arrow.triangle.2.circlepath",
    "bolt.fill",
    "server.rack",
    "network",
    "cloud.fill",
    "globe",
    "antenna.radiowaves.left.and.right",
    "externaldrive.fill",
    "arrow.triangle.branch",
    "arrow.triangle.pull",
    "arrow.merge",
    "chevron.left.forwardslash.chevron.right",
    "curlybraces",
    "doc.text.fill",
    "folder.fill",
    "checkmark.circle.fill",
    "xmark.circle.fill",
    "exclamationmark.triangle.fill",
    "ladybug.fill",
    "sparkles",
    "wand.and.stars",
    "brain.head.profile",
    "shippingbox.fill",
    "paperplane.fill",
    "archivebox.fill",
    "chart.line.uptrend.xyaxis",
    "chart.bar.fill",
    "magnifyingglass",
    "lock.fill",
    "key.fill",
    "cpu",
  ]
}

#if DEBUG
  #Preview("Default icon") {
    TabIconPickerView(
      initialIcon: nil,
      defaultIcon: TabIconSource(systemSymbol: "terminal"),
      onApply: { _ in },
      onCancel: {}
    )
  }

  #Preview("With override") {
    TabIconPickerView(
      initialIcon: "sparkles",
      defaultIcon: TabIconSource(systemSymbol: "terminal"),
      onApply: { _ in },
      onCancel: {}
    )
  }
#endif
