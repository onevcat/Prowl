import AppKit
import SwiftUI

struct WorktreeRow: View {
  let name: String
  let worktreeName: String
  let info: WorktreeInfoEntry?
  /// Per-worktree open-tab count badge; `nil` hides the badge entirely
  /// (workspace child rows — tab attribution is per directory, not per child).
  let tabCountBadge: WorktreeTabCountBadge?
  let iconSystemName: String?
  let showsPullRequestInfo: Bool
  let isHovered: Bool
  let isPinned: Bool
  let isMainWorktree: Bool
  let isLoading: Bool
  let taskStatus: WorktreeTaskStatus?
  let hasBlockedAgent: Bool
  let isRunScriptRunning: Bool
  let showsNotificationIndicator: Bool
  let notifications: [WorktreeTerminalNotification]
  let onFocusNotification: (WorktreeTerminalNotification) -> Void
  let shortcutHint: String?
  let showsShortcutHint: Bool
  let pinAction: (() -> Void)?
  let isSelected: Bool
  let archiveAction: (() -> Void)?
  let onDiffTap: (() -> Void)?
  let onStopRunScript: (() -> Void)?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.resolvedKeybindings) private var resolvedKeybindings

  init(
    name: String,
    worktreeName: String,
    info: WorktreeInfoEntry?,
    tabCountBadge: WorktreeTabCountBadge? = nil,
    iconSystemName: String? = nil,
    showsPullRequestInfo: Bool,
    isHovered: Bool,
    isPinned: Bool,
    isMainWorktree: Bool,
    isLoading: Bool,
    taskStatus: WorktreeTaskStatus?,
    hasBlockedAgent: Bool = false,
    isRunScriptRunning: Bool,
    showsNotificationIndicator: Bool,
    notifications: [WorktreeTerminalNotification],
    onFocusNotification: @escaping (WorktreeTerminalNotification) -> Void,
    shortcutHint: String?,
    showsShortcutHint: Bool,
    pinAction: (() -> Void)?,
    isSelected: Bool,
    archiveAction: (() -> Void)?,
    onDiffTap: (() -> Void)?,
    onStopRunScript: (() -> Void)?
  ) {
    self.name = name
    self.worktreeName = worktreeName
    self.info = info
    self.tabCountBadge = tabCountBadge
    self.iconSystemName = iconSystemName
    self.showsPullRequestInfo = showsPullRequestInfo
    self.isHovered = isHovered
    self.isPinned = isPinned
    self.isMainWorktree = isMainWorktree
    self.isLoading = isLoading
    self.taskStatus = taskStatus
    self.hasBlockedAgent = hasBlockedAgent
    self.isRunScriptRunning = isRunScriptRunning
    self.showsNotificationIndicator = showsNotificationIndicator
    self.notifications = notifications
    self.onFocusNotification = onFocusNotification
    self.shortcutHint = shortcutHint
    self.showsShortcutHint = showsShortcutHint
    self.pinAction = pinAction
    self.isSelected = isSelected
    self.archiveAction = archiveAction
    self.onDiffTap = onDiffTap
    self.onStopRunScript = onStopRunScript
  }

  var body: some View {
    // A blocked agent has stopped and is waiting on an answer, so it must not
    // wear the running spinner — that affordance tells you to wait, which is
    // the opposite of what a blocked agent needs. `isLoading` still wins: that
    // spinner describes the row's own create/archive/delete work, not an agent.
    let showsBlockedIndicator = hasBlockedAgent && !isLoading
    let showsSpinner = isLoading || (taskStatus == .running && !showsBlockedIndicator)
    let hidesBranchIcon = showsSpinner || showsBlockedIndicator
    let branchIconName =
      iconSystemName
      ?? (isMainWorktree ? "star.fill" : (isPinned ? "pin.fill" : "arrow.triangle.branch"))
    let display = WorktreePullRequestDisplay(
      worktreeName: name,
      pullRequest: showsPullRequestInfo ? info?.pullRequest : nil
    )
    let displayAddedLines = info?.addedLines
    let displayRemovedLines = info?.removedLines
    let lineChangePresentation: LineChangeBadgePresentation? =
      if let displayAddedLines, let displayRemovedLines {
        LineChangeBadgePresentation(
          addedLines: displayAddedLines,
          removedLines: displayRemovedLines,
          skippedUntrackedFileCount: info?.skippedUntrackedFileCount ?? 0
        )
      } else {
        nil
      }
    let mergeReadiness = pullRequestMergeReadiness(for: display.pullRequest)
    let isQueued =
      display.pullRequest.flatMap(PullRequestMergeQueueStatus.init(pullRequest:)) != nil
    let showsPullRequestTag = display.pullRequest != nil && display.pullRequestBadgeStyle != nil
    let nameColor = colorScheme == .dark ? Color.white : Color.primary
    let detailText = worktreeName.isEmpty ? name : worktreeName
    let bodyFontAscender = NSFont.preferredFont(forTextStyle: .body).ascender
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        ZStack {
          if showsNotificationIndicator {
            NotificationPopoverButton(
              notifications: notifications,
              onFocusNotification: onFocusNotification
            ) {
              Image(systemName: "bell.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Unread notifications")
            }
            .opacity(hidesBranchIcon ? 0 : 1)
          } else {
            Image(systemName: branchIconName)
              .font(.caption)
              .foregroundStyle(.secondary)
              .opacity(hidesBranchIcon ? 0 : 1)
              .accessibilityHidden(true)
          }
          if showsBlockedIndicator {
            Image(systemName: "exclamationmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .accessibilityLabel("Agent is waiting for your input")
          } else if showsSpinner {
            ProgressView()
              .controlSize(.small)
          }
        }
        .frame(width: 16, height: 16)
        .alignmentGuide(.firstTextBaseline) { _ in
          bodyFontAscender
        }
        Text(name)
          .font(.body)
          .foregroundStyle(nameColor)
          .lineLimit(1)
          .truncationMode(.middle)
          .layoutPriority(1)
          .help(name)
        if let tabCountBadge {
          tabCountBadge
        }
        Spacer(minLength: 4)
        if isHovered, pinAction != nil {
          Button {
            pinAction?()
          } label: {
            Image(systemName: isPinned ? "pin.slash" : "pin")
              .font(.caption)
              .contentTransition(.symbolEffect(.replace))
              .accessibilityLabel(isPinned ? "Unpin worktree" : "Pin worktree")
          }
          .buttonStyle(.plain)
          .help(isPinned ? "Unpin" : "Pin to top")
        }
        if isHovered, archiveAction != nil {
          Button {
            archiveAction?()
          } label: {
            Image(systemName: "archivebox")
              .font(.caption)
              .accessibilityLabel("Archive worktree")
          }
          .buttonStyle(.plain)
          .help("Archive Worktree")
        }
        if isRunScriptRunning {
          RunScriptIndicator(onStop: onStopRunScript)
        }
        if let lineChangePresentation {
          Button {
            onDiffTap?()
          } label: {
            WorktreeRowChangeCountView(
              presentation: lineChangePresentation,
              isSelected: isSelected,
            )
          }
          .buttonStyle(.plain)
          .help(
            [
              AppShortcuts.helpText(
                title: "Show Diff",
                commandID: AppShortcuts.CommandID.showDiff,
                in: resolvedKeybindings
              ),
              lineChangePresentation.incompleteCountDescription,
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
          )
        }
      }
      WorktreeRowInfoView(
        worktreeName: detailText,
        showsPullRequestTag: showsPullRequestTag,
        pullRequestNumber: display.pullRequest?.number,
        pullRequestURL: display.pullRequest.flatMap { URL(string: $0.url) },
        pullRequestState: display.pullRequestState,
        mergeReadiness: mergeReadiness,
        isQueued: isQueued,
        shortcutHint: shortcutHint,
        showsShortcutHint: showsShortcutHint
      )
      .padding(.leading, 22)
    }
    .padding(.horizontal, 2)
    .frame(maxWidth: .infinity, minHeight: worktreeRowHeight, alignment: .center)
  }

  private func pullRequestMergeReadiness(
    for pullRequest: GithubPullRequest?
  ) -> PullRequestMergeReadiness? {
    guard let pullRequest, pullRequest.state.uppercased() == "OPEN" else {
      return nil
    }
    return PullRequestMergeReadiness(pullRequest: pullRequest)
  }

  private var worktreeRowHeight: CGFloat {
    36
  }
}

private struct RunScriptIndicator: View {
  let onStop: (() -> Void)?
  @State private var isHovering = false

  var body: some View {
    Button {
      onStop?()
    } label: {
      Image(systemName: isHovering ? "stop.fill" : "play.fill")
        .font(.caption)
        .foregroundStyle(isHovering ? .red : .green)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityLabel(isHovering ? "Stop run script" : "Run script active")
    }
    .buttonStyle(.plain)
    .help(isHovering ? "Stop Script" : "Run script active")
    .disabled(onStop == nil)
    .onHover { isHovering = $0 }
  }
}

private struct WorktreeRowInfoView: View {
  let worktreeName: String
  let showsPullRequestTag: Bool
  let pullRequestNumber: Int?
  let pullRequestURL: URL?
  let pullRequestState: String?
  let mergeReadiness: PullRequestMergeReadiness?
  let isQueued: Bool
  let shortcutHint: String?
  let showsShortcutHint: Bool

  var body: some View {
    HStack(spacing: 4) {
      summaryText
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
      Spacer(minLength: 0)
      if let shortcutHint {
        ShortcutHintView(text: shortcutHint, color: .secondary)
          .opacity(showsShortcutHint ? 1 : 0)
          .accessibilityHidden(!showsShortcutHint)
      }
    }
    .font(.caption)
    .frame(minHeight: 14)
    .animation(.easeInOut(duration: 0.15), value: showsShortcutHint)
  }

  private var summaryText: Text {
    var result = AttributedString()
    func appendSeparator() {
      if !result.characters.isEmpty {
        var sep = AttributedString(" \u{2022} ")
        sep.foregroundColor = .secondary
        result.append(sep)
      }
    }
    if !worktreeName.isEmpty {
      var segment = AttributedString(worktreeName)
      segment.foregroundColor = .secondary
      result.append(segment)
    }
    if showsPullRequestTag, let pullRequestNumber {
      appendSeparator()
      var segment = AttributedString("PR #\(pullRequestNumber)")
      segment.foregroundColor = .secondary
      // Clickable via `Text`'s built-in link handling; the rest of the row
      // keeps its tap-to-select behavior.
      segment.link = pullRequestURL
      result.append(segment)
    }
    if pullRequestState == "MERGED" {
      appendSeparator()
      var segment = AttributedString("Merged")
      segment.foregroundColor = PullRequestBadgeStyle.mergedColor
      result.append(segment)
    } else if pullRequestState == "CLOSED" {
      appendSeparator()
      var segment = AttributedString("Closed")
      segment.foregroundColor = PullRequestBadgeStyle.closedColor
      result.append(segment)
    } else if isQueued {
      // A queued PR is mid-merge, so the queue state takes priority over the
      // merge-readiness label.
      appendSeparator()
      var segment = AttributedString("Queued")
      segment.foregroundColor = PullRequestBadgeStyle.queuedColor
      result.append(segment)
    } else if let mergeReadiness {
      appendSeparator()
      var segment = AttributedString(mergeReadiness.label)
      segment.foregroundColor = mergeStatusColor(mergeReadiness)
      result.append(segment)
    }
    return Text(result)
  }

  private func mergeStatusColor(_ readiness: PullRequestMergeReadiness) -> Color {
    switch readiness.blockingReason {
    case .none:
      return .green
    case .mergeConflicts, .changesRequested, .checksFailed, .blocked:
      return .red
    case .checksPending:
      return .yellow
    }
  }
}

// MARK: - Previews

@MainActor
private struct WorktreeRowPreview: View {
  @State private var hoveredID: String?

  var body: some View {
    List {
      row(id: "main", name: "main", worktreeName: "Default", isMainWorktree: true)
      row(
        id: "diff", name: "feature/sidebar-redesign", worktreeName: "sidebar-redesign",
        addedLines: 120, removedLines: 45
      )
      row(
        id: "long-diff",
        name: "feature/long-running-sidebar-layout-stress-case",
        worktreeName: "sidebar-layout-stress",
        addedLines: 632,
        removedLines: 344
      )
      row(
        id: "pinned", name: "feature/pinned-branch", worktreeName: "pinned-branch", isPinned: true)
      row(id: "running", name: "feature/auth-flow", worktreeName: "auth-flow", taskStatus: .running)
      row(id: "loading", name: "creating-worktree...", worktreeName: "Setting up", isLoading: true)
      row(
        id: "notif", name: "feature/notifications", worktreeName: "notifications",
        showsNotificationIndicator: true)
      row(
        id: "script", name: "feature/run-script", worktreeName: "run-script",
        isRunScriptRunning: true)
      row(id: "hint", name: "feature/shortcuts", worktreeName: "shortcuts", shortcutHint: "⌘1")
      row(id: "selected", name: "feature/selected", worktreeName: "selected", isSelected: true)
    }
    .listStyle(.sidebar)
    .scrollIndicators(.never)
    .frame(width: 280, height: 550)
  }

  private func row(
    id: String,
    name: String,
    worktreeName: String,
    isPinned: Bool = false,
    isMainWorktree: Bool = false,
    isLoading: Bool = false,
    taskStatus: WorktreeTaskStatus? = nil,
    isRunScriptRunning: Bool = false,
    showsNotificationIndicator: Bool = false,
    addedLines: Int? = nil,
    removedLines: Int? = nil,
    isSelected: Bool = false,
    shortcutHint: String? = nil
  ) -> some View {
    let info: WorktreeInfoEntry? =
      if let addedLines, let removedLines {
        WorktreeInfoEntry(addedLines: addedLines, removedLines: removedLines, pullRequest: nil)
      } else {
        nil
      }
    let isHovered = hoveredID == id
    return WorktreeRow(
      name: name,
      worktreeName: worktreeName,
      info: info,
      showsPullRequestInfo: false,
      isHovered: isHovered,
      isPinned: isPinned,
      isMainWorktree: isMainWorktree,
      isLoading: isLoading,
      taskStatus: taskStatus,
      isRunScriptRunning: isRunScriptRunning,
      showsNotificationIndicator: showsNotificationIndicator,
      notifications: [],
      onFocusNotification: { _ in },
      shortcutHint: shortcutHint,
      showsShortcutHint: shortcutHint != nil,
      pinAction: {},
      isSelected: isSelected,
      archiveAction: {},
      onDiffTap: addedLines != nil ? {} : nil,
      onStopRunScript: isRunScriptRunning ? {} : nil
    )
    .listRowInsets(EdgeInsets())
    .listRowSeparator(.hidden)
    .onHover { hovering in
      hoveredID = hovering ? id : nil
    }
  }
}

#Preview("WorktreeRow") {
  WorktreeRowPreview()
}

// MARK: - Subviews

private struct WorktreeRowChangeCountView: View {
  let presentation: LineChangeBadgePresentation
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 4) {
      Text(presentation.addedText)
        .foregroundStyle(.green)
      Text(presentation.removedText)
        .foregroundStyle(.red)
        .baselineOffset(-1)
    }
    .font(.caption)
    .lineLimit(1)
    .padding(.horizontal, 4)
    .padding(.vertical, 0)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.accessibilityLabel)
    .overlay {
      Capsule()
        .stroke(
          isSelected ? AnyShapeStyle(.secondary.opacity(0.3)) : AnyShapeStyle(.tertiary),
          lineWidth: 1)
    }
    .monospacedDigit()
  }
}
