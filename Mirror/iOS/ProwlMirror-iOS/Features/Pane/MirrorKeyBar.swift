import SwiftUI

/// The keys a TUI needs that a phone keyboard lacks (docs-ai 089 S5): Return, the arrows,
/// Escape, Tab and Shift-Tab, Control-C. Shown under the terminal screen; a refusal shows in the
/// composer's note, like a refused Stop.
///
/// Ordered by use, so the common keys fit without scrolling the bar. An agent's menus take
/// Up/Down and Return, so Return comes first and stands out; Control-C can end the agent, so it
/// is last. A shell interrupts, completes and recalls more than it navigates.
struct MirrorKeyBar: View {
  @Bindable var session: MirrorSession

  struct Key: Identifiable, Equatable {
    let token: String
    let label: String
    let symbol: String?
    let help: LocalizedStringKey
    var id: String { token }

    static func == (lhs: Key, rhs: Key) -> Bool { lhs.token == rhs.token }
  }

  private static let enter = Key(token: "enter", label: "Return", symbol: "return", help: "Press Return on the Mac")
  private static let upArrow = Key(token: "up", label: "Up", symbol: "arrow.up", help: "Press Up Arrow on the Mac")
  private static let downArrow = Key(
    token: "down", label: "Down", symbol: "arrow.down", help: "Press Down Arrow on the Mac")
  private static let leftArrow = Key(
    token: "left", label: "Left", symbol: "arrow.left", help: "Press Left Arrow on the Mac")
  private static let rightArrow = Key(
    token: "right", label: "Right", symbol: "arrow.right", help: "Press Right Arrow on the Mac")
  private static let esc = Key(token: "esc", label: "esc", symbol: nil, help: "Press Escape on the Mac")
  private static let tab = Key(token: "tab", label: "⇥", symbol: nil, help: "Press Tab on the Mac")
  private static let shiftTab = Key(token: "shift-tab", label: "⇧⇥", symbol: nil, help: "Press Shift-Tab on the Mac")
  private static let controlC = Key(token: "ctrl-c", label: "⌃C", symbol: nil, help: "Press Control-C on the Mac")

  /// The keys for an agent pane, or for a shell when `agent` is false.
  static func keys(agent: Bool) -> [Key] {
    agent
      ? [enter, upArrow, downArrow, esc, tab, shiftTab, leftArrow, rightArrow, controlC]
      : [enter, controlC, tab, upArrow, downArrow, esc, leftArrow, rightArrow, shiftTab]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(Self.keys(agent: session.pane?.agent != nil)) { key in
            keyButton(key)
              // Disabled while a message is being delivered; the Host takes one command at a time.
              .disabled(!session.canSendKeys)
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

  /// Return is the prominent key: it confirms the row the arrows chose.
  @ViewBuilder private func keyButton(_ key: Key) -> some View {
    let button = Button {
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
    if key == Self.enter {
      button.buttonStyle(.glassProminent)
    } else {
      button.buttonStyle(.glass)
    }
  }
}
