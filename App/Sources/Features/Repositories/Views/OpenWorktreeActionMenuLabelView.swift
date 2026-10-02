import AppKit
import SwiftUI

struct OpenWorktreeActionMenuLabelView: View {
  let action: OpenWorktreeAction
  let shortcutHint: String?

  var body: some View {
    HStack(spacing: 6) {
      if let icon = action.menuIcon {
        switch icon {
        case .app(let image):
          Image(nsImage: image)
            .renderingMode(.original)
            .accessibilityHidden(true)
        case .symbol(let name):
          Image(systemName: name)
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
        }
      }
      if let shortcutHint {
        HStack(spacing: 2) {
          Text(action.labelTitle)
            .font(.body)
          Text("(\(shortcutHint))")
            .font(.body)
            .foregroundStyle(.secondary)
        }
      } else {
        Text(action.labelTitle)
          .font(.body)
      }
    }
  }
}
