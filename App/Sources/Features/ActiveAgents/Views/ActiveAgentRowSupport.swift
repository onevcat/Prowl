import AppKit
import ComposableArchitecture
import SwiftUI

enum ActiveAgentRowPresentation {
  static func subtitle(
    for entry: ActiveAgentEntry,
    branchName: String,
    showTabTitles: Bool,
    workflowBadge: String? = nil
  ) -> String {
    workflowBadge ?? (showTabTitles ? paneTitle(for: entry) : branchName)
  }

  static func helpText(
    for entry: ActiveAgentEntry,
    branchName: String,
    showTabTitles: Bool,
    showAgentName: Bool = true
  ) -> String {
    [
      showAgentName ? nil : entry.displayName,
      showTabTitles ? branchName : paneTitle(for: entry),
      remoteHelpText(for: entry),
    ]
    .compactMap(\.self)
    .joined(separator: "\n")
  }

  /// The row's icon is hidden from accessibility, so a hidden name must still be spoken here.
  static func repositoryAccessibilityLabel(
    for entry: ActiveAgentEntry,
    repositoryName: String,
    showAgentName: Bool
  ) -> String {
    showAgentName ? repositoryName : "\(entry.displayName), \(repositoryName)"
  }

  /// The reason a remote agent's observation rests on what it does; nil for a local agent.
  /// The island roster, whose subtitle already shows title and branch, uses it alone.
  static func remoteHelpText(for entry: ActiveAgentEntry) -> String? {
    entry.remote.map(RemoteAgentPresentation.explanation)
  }

  /// The island roster has room for both, so it shows "pane title · branch" regardless of the
  /// sidebar's either/or setting. A live Workflow badge still takes the whole line.
  static func combinedSubtitle(
    for entry: ActiveAgentEntry,
    branchName: String,
    workflowBadge: String? = nil
  ) -> String {
    if let workflowBadge { return workflowBadge }
    let title = paneTitle(for: entry)
    return title == branchName ? title : "\(title) \u{00B7} \(branchName)"
  }

  static func paneTitle(for entry: ActiveAgentEntry) -> String {
    let trimmed = entry.paneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? String(localized: "Untitled tab") : trimmed
  }
}

struct ActiveAgentRowContextMenu: View {
  @Dependency(FeatureFlags.self) private var featureFlags
  let entry: ActiveAgentEntry
  let directory: URL?
  let send: (ActiveAgentsFeature.Action) -> Void

  @Dependency(WorkflowStartClient.self) private var workflowStartClient

  var body: some View {

    if featureFlags.workflowUI {
      runWorkflowMenu
    }

    Button("Mark as Read") {
      send(.markAsReadTapped(entry.id))
    }
    .help("Clear this agent's unread notifications without switching to it")

    // A remote agent's directory is on its host; the local path is the `ssh`'s.
    if let directory, entry.remote == nil {
      Divider()
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory.path, forType: .string)
      }
      .help("Copy the agent's working directory path")
      Button("Reveal in Finder") {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
      }
      .help("Reveal the agent's working directory in Finder")
    }

    if let transcriptPath = entry.session?.transcriptPath {
      Divider()
      Button("Copy Session Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptPath.path, forType: .string)
      }
      .help("Copy the on-disk path of this agent's session log")
      Button("Reveal Session in Finder") {
        NSWorkspace.shared.selectFile(
          transcriptPath.path,
          inFileViewerRootedAtPath: transcriptPath.deletingLastPathComponent().path
        )
      }
      .help("Select this agent's session log in Finder")
    }
  }

  /// The catalog is read when the menu opens, so file edits show without a relaunch.
  @ViewBuilder
  private var runWorkflowMenu: some View {
    let workflows = workflowStartClient.catalog(entry.worktreeID).filter(\.isRunnable)
    if !workflows.isEmpty {
      Menu("Run Workflow") {
        ForEach(workflows) { item in
          Button(item.name) {
            send(.runWorkflowTapped(entry.id, workflowKey: item.key))
          }
          .help(item.workflowDescription ?? String(localized: "Run \(item.name) from this agent's pane"))
        }
      }
    }
  }
}
