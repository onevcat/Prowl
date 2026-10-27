import IdentifiedCollections
import Sharing
import SwiftUI

/// The background connection of the selected worktree's remote folder, for the toolbar
/// status (docs-ai 084 C1): Prowl keeps it while the host's folders are in the sidebar.
struct RemoteFolderToolbarStatus: Equatable {
  let hostProfileID: HostProfile.ID
  let alias: String
  /// Nil while the host answers.
  let hostStatus: RemoteHostStatus?
  /// False until the host answered since Prowl started: the folder then shows its last
  /// state, and Prowl is still connecting.
  let hasAnswered: Bool

  /// Nil for a local worktree, and for a remote folder that holds no connection: a plain
  /// folder is not polled (B3f), and a folder without its host profile cannot connect.
  init?(worktree: Worktree?, repositories: RepositoriesFeature.State) {
    guard let worktree, let hostProfileID = worktree.repositoryLocation.hostProfileID else { return nil }
    let repositoryID = worktree.repositoryLocation.standardized.id
    guard repositories.repositories[id: repositoryID]?.kind == .git else { return nil }
    @Shared(.hostProfiles) var hostProfiles: [HostProfile]
    guard let alias = hostProfiles.first(where: { $0.id == hostProfileID })?.alias else { return nil }
    self.init(
      hostProfileID: hostProfileID, alias: alias, hostStatus: repositories.remoteHostStatus(for: repositoryID),
      hasAnswered: repositories.answeredRemoteRepositoryIDs.contains(repositoryID))
  }

  init(hostProfileID: HostProfile.ID, alias: String, hostStatus: RemoteHostStatus?, hasAnswered: Bool = true) {
    self.hostProfileID = hostProfileID
    self.alias = alias
    self.hostStatus = hostStatus
    self.hasAnswered = hasAnswered
  }

  var summary: String {
    switch hostStatus {
    case nil where hasAnswered: String(localized: "Connected")
    case nil: String(localized: "Connecting…")
    case .unreachable: String(localized: "Not answering")
    case .connectionFailed: String(localized: "Not connected")
    case .needsRebind: String(localized: "SSH configuration changed")
    }
  }
}

/// The host of the selected remote folder and how it answers. A click opens a panel that
/// tells what the background connection does, with Rebind Host when the SSH configuration
/// changed.
struct RemoteFolderStatusButton: View {
  let status: RemoteFolderToolbarStatus
  let onRebind: () -> Void
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: symbol)
          .foregroundStyle(status.hostStatus == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
          .accessibilityHidden(true)
        Text(verbatim: status.alias)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(status.summary)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .buttonStyle(.plain)
    .font(.caption)
    .contentShape(.rect)
    .help("Prowl's background SSH connection to the host of this remote project. Click to see what it does.")
    .accessibilityLabel(Text("\(status.alias): \(status.summary)"))
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      RemoteFolderStatusPanel(status: status) {
        isPresented = false
        onRebind()
      }
    }
  }

  private var symbol: String {
    switch status.hostStatus {
    case nil: "network"
    case .unreachable, .connectionFailed: "network.slash"
    case .needsRebind: "exclamationmark.triangle.fill"
    }
  }
}

private struct RemoteFolderStatusPanel: View {
  let status: RemoteFolderToolbarStatus
  let onRebind: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text("Remote project over SSH")
          .font(.headline)
      } icon: {
        Image(systemName: "network")
          .accessibilityHidden(true)
      }
      Text(
        """
        Prowl keeps a background SSH connection to \(status.alias) while its folders are in the \
        sidebar. Over it, Prowl reads the folders' worktrees and changes: every \(Self.focused) seconds \
        for the selected folder, and every \(Self.background) seconds for the others. While the \
        host does not answer, it tries less often, at most every \(Self.slowest) minutes.
        """
      )
      .fixedSize(horizontal: false, vertical: true)
      Text(detail)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if case .needsRebind = status.hostStatus {
        HStack {
          Spacer()
          Button("Rebind Host…", action: onRebind)
            .focusable(false)
            .help("Show the new target of this host's SSH configuration and use it")
        }
      }
    }
    .font(.callout)
    .padding(16)
    .frame(width: 380)
  }

  private static let focused = Int(RepositoriesFeature.remoteRefreshFocusedInterval.components.seconds)
  private static let background = Int(RepositoriesFeature.remoteRefreshBackgroundInterval.components.seconds)
  private static let slowest = Int(RepositoriesFeature.remoteRefreshMaximumBackoff.components.seconds) / 60

  private var detail: String {
    switch status.hostStatus {
    case nil where status.hasAnswered:
      String(localized: "Connected.")
    case nil:
      String(localized: "Prowl is connecting to the host. Until it answers, the folders show their last state.")
    case .unreachable:
      String(localized: "The host did not answer. Prowl shows the last state and tries again.")
    case .connectionFailed(let reason):
      String(localized: "Prowl could not connect: \(reason) It shows the last state and tries again.")
    case .needsRebind:
      String(
        localized: """
          The SSH configuration of \(status.alias) now reaches another user, host or port. Prowl does \
          not connect to it until you rebind it.
          """)
    }
  }
}
