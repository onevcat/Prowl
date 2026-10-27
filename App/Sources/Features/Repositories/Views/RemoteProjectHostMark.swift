import SwiftUI

/// What the sidebar tells about the host of a remote project: the name the user gave the
/// host, the target that SSH resolved for it (`ssh -G`: user, host name or address, port,
/// jump hosts), and the path on the host.
struct RemoteProjectHostSummary: Equatable {
  /// Nil when `hosts.json` no longer has the project's host.
  let profile: HostProfile?
  let path: String

  /// Nil for a local project.
  init?(location: RepositoryLocation, hostProfiles: [HostProfile]) {
    guard case .remote(let hostProfileID, let path) = location else { return nil }
    profile = hostProfiles.first { $0.id == hostProfileID }
    self.path = path
  }

  var title: String {
    guard let profile else { return String(localized: "Remote project on an unknown host") }
    return String(localized: "Remote project on \(profile.alias)")
  }

  /// One fact on each line, for a tooltip.
  var details: String {
    var lines = [title]
    if let key = profile?.connectionKey {
      let target = key.port == 22 ? key.label : "\(key.label):\(key.port)"
      lines.append(String(localized: "Host: \(target)"))
      if !key.jumpChain.isEmpty {
        lines.append(String(localized: "Through: \(key.jumpChain.joined(separator: " → "))"))
      }
    }
    lines.append(String(localized: "Path: \(path)"))
    return lines.joined(separator: "\n")
  }
}

/// The globe before the name of a remote project in the sidebar. Its tooltip names the host.
struct RemoteProjectHostMark: View {
  let summary: RemoteProjectHostSummary

  var body: some View {
    Image(systemName: "network")
      .font(.caption)
      .foregroundStyle(.secondary)
      .help(Text(verbatim: summary.details))
      .accessibilityLabel(Text(verbatim: summary.title))
  }
}
