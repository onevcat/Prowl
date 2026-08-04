import SwiftUI

struct EmptyTerminalPaneView: View {
  let message: String

  var body: some View {
    VStack {
      Text(message)
        .interfaceFont(.headline)
      Text("Use the plus button to open a terminal.")
        .interfaceFont(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .multilineTextAlignment(.center)
  }
}
