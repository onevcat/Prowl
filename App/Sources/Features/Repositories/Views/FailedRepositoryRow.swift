import SwiftUI

struct FailedRepositoryRow: View {
  let name: String
  let path: String
  let isGitUnavailable: Bool
  var hostStatus: RemoteHostStatus?
  var rebind: () -> Void = {}
  let retry: () -> Void
  let showFailure: () -> Void
  let removeRepository: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .foregroundStyle(.secondary)
        Group {
          if isGitUnavailable {
            Text("Git is unavailable")
          } else if case .needsRebind = hostStatus {
            Text("The SSH configuration changed")
          } else if hostStatus == .unreachable {
            Text("The host did not answer")
          } else {
            Text("Unable to read repository")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        Text(path)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      if case .needsRebind = hostStatus {
        Button("Rebind Host", systemImage: "arrow.triangle.2.circlepath", action: rebind)
          .labelStyle(.iconOnly)
          .help("Use the new target of this host's SSH configuration")
      }
      Button("Retry", systemImage: "arrow.clockwise", action: retry)
        .labelStyle(.iconOnly)
        .help("Retry loading repository")
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
