import SwiftUI

/// The keys a TUI needs that a phone keyboard lacks (docs-ai 089 S5): Escape, Control-C,
/// Shift-Tab and Tab, the arrows, Return. Shown under the terminal screen of an agent pane; a
/// refusal shows in the composer's note, like a refused Stop.
struct MirrorKeyBar: View {
  @Bindable var session: MirrorSession

  private struct Key: Identifiable {
    let token: String
    let label: String
    let symbol: String?
    let help: LocalizedStringKey
    var id: String { token }
  }

  private static let keys: [Key] = [
    Key(token: "esc", label: "esc", symbol: nil, help: "Press Escape on the Mac"),
    Key(token: "ctrl-c", label: "⌃C", symbol: nil, help: "Press Control-C on the Mac"),
    Key(token: "shift-tab", label: "⇧⇥", symbol: nil, help: "Press Shift-Tab on the Mac"),
    Key(token: "tab", label: "⇥", symbol: nil, help: "Press Tab on the Mac"),
    Key(token: "up", label: "Up", symbol: "arrow.up", help: "Press Up Arrow on the Mac"),
    Key(token: "down", label: "Down", symbol: "arrow.down", help: "Press Down Arrow on the Mac"),
    Key(token: "left", label: "Left", symbol: "arrow.left", help: "Press Left Arrow on the Mac"),
    Key(token: "right", label: "Right", symbol: "arrow.right", help: "Press Right Arrow on the Mac"),
    Key(token: "enter", label: "Return", symbol: "return", help: "Press Return on the Mac"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(Self.keys) { key in
            Button {
              session.sendKeys([key.token])
            } label: {
              Group {
                if let symbol = key.symbol {
                  Image(systemName: symbol).accessibilityLabel(Text(key.label))
                } else {
                  Text(key.label).monospaced()
                }
              }
              .font(.subheadline.weight(.medium))
              .frame(minWidth: 30, minHeight: 22)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("key-\(key.token)")
            .help(key.help)
          }
        }
        .padding(.horizontal, 2)
      }
      .scrollClipDisabled()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("key-bar")
  }
}
