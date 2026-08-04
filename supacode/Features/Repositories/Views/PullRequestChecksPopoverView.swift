import SwiftUI

struct PullRequestChecksPopoverView: View {
  let pullRequest: GithubPullRequest
  let checks: [GithubPullRequestStatusCheck]
  private let breakdown: PullRequestCheckBreakdown
  private let sortedChecks: [GithubPullRequestStatusCheck]
  @Environment(\.analyticsClient) private var analyticsClient
  @Environment(\.openURL) private var openURL
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  init(
    pullRequest: GithubPullRequest,
    checks: [GithubPullRequestStatusCheck]
  ) {
    self.pullRequest = pullRequest
    self.checks = checks
    self.breakdown = PullRequestCheckBreakdown(checks: checks)
    self.sortedChecks = checks.sorted {
      let left = Self.sortRank(for: $0.checkState)
      let right = Self.sortRank(for: $1.checkState)
      if left == right {
        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      return left < right
    }
  }

  var body: some View {
    let pullRequestURL = URL(string: pullRequest.url)
    let stateLabel = pullRequest.state.uppercased()
    let draftLabel = pullRequest.isDraft ? "\(stateLabel)/DRAFT" : stateLabel
    let titlePrefix = Text("\(draftLabel) - ").foregroundStyle(.secondary)
    let titleSuffix = Text(verbatim: " #\(pullRequest.number)")
      .foregroundStyle(.secondary)
    let titleLine = Text("\(titlePrefix)\(pullRequest.title)\(titleSuffix)")
    let authorLogin = pullRequest.authorLogin ?? "Someone"
    let commitsCount = pullRequest.commitsCount ?? 0
    let commitsLabel = commitsCount == 1 ? "commit" : "commits"
    let baseRefName = pullRequest.baseRefName ?? "base"
    let headRefName = pullRequest.headRefName ?? "branch"
    let baseRef = Text("`\(baseRefName)`").monospaced()
    let headRef = Text("`\(headRefName)`").monospaced()
    let summaryLine = Text(
      "\(authorLogin) wants to merge \(commitsCount, format: .number) \(commitsLabel) into \(baseRef) from \(headRef)"
    ).foregroundStyle(.secondary)
    let additionsText = Text("+\(pullRequest.additions, format: .number)")
    let deletionsText = Text("-\(pullRequest.deletions, format: .number)")
    let hasConflicts = PullRequestMergeReadiness(pullRequest: pullRequest).isConflicting
    ScrollView {
      VStack(alignment: .leading) {
        if let pullRequestURL {
          Button {
            analyticsClient.capture("github_pr_opened", nil)
            openURL(pullRequestURL)
          } label: {
            titleLine
              .lineLimit(1)
          }
          .buttonStyle(.plain)
          .focusable(false)
          .onHover { _ in }
          .pointerStyle(.link)
          .help(openPullRequestHelpText)
          .modifier(KeyboardShortcutModifier(shortcut: openPullRequestShortcut?.keyboardShortcut))
          .interfaceFont(.headline)
        } else {
          titleLine
            .lineLimit(1)
            .interfaceFont(.headline)
        }
        summaryLine
          .interfaceFont(.subheadline)
          .lineLimit(1)
        HStack {
          additionsText
            .foregroundStyle(.green)
          deletionsText
            .foregroundStyle(.red)
          if hasConflicts {
            Text("•")
              .foregroundStyle(.secondary)
            Text("Merge Conflicts")
              .foregroundStyle(.red)
          }
        }
        .interfaceFont(.subheadline)

        if let mergeQueueStatus = PullRequestMergeQueueStatus(pullRequest: pullRequest) {
          PullRequestMergeQueueRow(status: mergeQueueStatus)
        }

        if breakdown.total > 0 {
          HStack {
            PullRequestChecksRingView(breakdown: breakdown)
            Text(breakdown.summaryText)
              .foregroundStyle(.secondary)
          }
          .interfaceFont(.caption)
        }

        if !sortedChecks.isEmpty {
          Divider()
          VStack(alignment: .leading) {
            ForEach(sortedChecks, id: \.self) { check in
              let style = PullRequestCheckStatusStyle(state: check.checkState)
              HStack {
                Image(systemName: style.symbol)
                  .foregroundStyle(style.color)
                  .accessibilityHidden(true)
                if let url = check.detailsUrl.flatMap(URL.init(string:)) {
                  Button {
                    analyticsClient.capture("github_ci_check_opened", nil)
                    openURL(url)
                  } label: {
                    LinkLabel(text: check.displayName)
                      .lineLimit(1)
                  }
                  .buttonStyle(.plain)
                  .focusable(false)
                  .help("Open check details on GitHub")
                } else {
                  Text(check.displayName)
                    .lineLimit(1)
                }
                Spacer()
                Text(style.label)
                  .foregroundStyle(.secondary)
              }
              .interfaceFont(.caption)
            }
          }
        }
      }
      .padding()
    }
    .frame(minWidth: 260, maxWidth: 840, maxHeight: 720)
  }

  private struct PullRequestMergeQueueRow: View {
    let status: PullRequestMergeQueueStatus

    var body: some View {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Image(systemName: "arrow.triangle.merge")
            .foregroundStyle(.brown)
            .accessibilityHidden(true)
          Text(status.summary)
            .foregroundStyle(.brown)
        }
        .interfaceFont(.subheadline)
        if let detail = status.detail {
          Text(detail)
            .interfaceFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
    }
  }

  private static func sortRank(for state: GithubPullRequestCheckState) -> Int {
    switch state {
    case .failure:
      return 0
    case .inProgress:
      return 1
    case .expected:
      return 2
    case .skipped:
      return 3
    case .success:
      return 4
    }
  }

  private var openPullRequestShortcut: AppShortcut? {
    AppShortcuts.resolvedShortcut(
      for: AppShortcuts.CommandID.openPullRequest,
      in: resolvedKeybindings
    )
  }

  private var openPullRequestHelpText: String {
    if let display = openPullRequestShortcut?.display {
      return "Open pull request on GitHub (\(display))"
    }
    return "Open pull request on GitHub"
  }
}

private struct LinkLabel: View {
  let text: String
  @State private var isHovering = false

  var body: some View {
    Text(text)
      .underline()
      .foregroundStyle(isHovering ? .blue : .secondary)
      .onHover { hovering in
        isHovering = hovering
      }
      .pointerStyle(.link)
      .accessibilityHint("Open on GitHub")
  }
}
