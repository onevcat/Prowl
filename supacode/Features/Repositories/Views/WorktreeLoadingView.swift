import SwiftUI

struct WorktreeLoadingView: View {
  let info: WorktreeLoadingInfo
  @Environment(\.surfaceBackgroundOpacity) private var surfaceBackgroundOpacity

  var body: some View {
    let statusCommand = info.statusCommand
    VStack(spacing: 12) {
      ProgressView()
        .controlSize(.large)
      Text(info.name)
        .interfaceFont(.title3)
        .lineLimit(1)
        .truncationMode(.middle)
      if let statusCommand {
        Text(statusCommand)
          .interfaceFont(.subheadline)
          .monospaced()
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Text(info.statusSubtitle)
        .interfaceFont(.subheadline)
        .monospaced()
        .foregroundStyle(.tertiary)
        .lineLimit(5, reservesSpace: true)
        .truncationMode(.head)
        .contentTransition(.opacity)
        .animation(.easeInOut, value: info.statusSubtitle)
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .background(Color(nsColor: .windowBackgroundColor).opacity(surfaceBackgroundOpacity))
  }
}
