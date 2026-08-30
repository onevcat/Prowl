import SwiftUI

struct FailedRepositoryRow: View {
  let name: String
  let path: String
  let showFailure: () -> Void
  let removeRepository: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .interfaceFont(.body)
          .foregroundStyle(.secondary)
        Text(path)
          .interfaceFont(.caption)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      Button("Show load failure", systemImage: "exclamationmark.triangle.fill", action: showFailure)
        .labelStyle(.iconOnly)
        .foregroundStyle(.red)
        .help("Show load failure")
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button("Remove Repository", action: removeRepository)
        .help("Remove repository ")
    }
    .selectionDisabled(true)
  }
}
