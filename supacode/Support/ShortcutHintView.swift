import SwiftUI

struct ShortcutHintView: View {
  let text: String
  let color: Color
  let font: Font

  init(text: String, color: Color, font: Font = .caption2) {
    self.text = text
    self.color = color
    self.font = font
  }

  var body: some View {
    Text(text)
      .font(font)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .foregroundStyle(color)
  }
}
