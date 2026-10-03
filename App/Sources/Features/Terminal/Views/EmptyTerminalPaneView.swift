import SwiftUI

struct EmptyTerminalPaneView: View {
  let message: String

  var body: some View {
    VStack {
      Text(message)
        .font(.headline)
      Text("Use the plus button to open a terminal.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .multilineTextAlignment(.center)
  }
}
