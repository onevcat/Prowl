import SwiftUI

struct ShortcutHintView: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .interfaceFont(.caption2)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .foregroundStyle(color)
  }
}
