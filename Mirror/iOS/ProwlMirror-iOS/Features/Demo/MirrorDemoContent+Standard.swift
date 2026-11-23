import Foundation

extension MirrorDemoContent {
  /// Stable pane IDs, so UI tests can find the demo panes.
  enum PaneID {
    static let blocked = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
    static let working = UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!
    static let done = UUID(uuidString: "D0000000-0000-0000-0000-000000000003")!
    static let idle = UUID(uuidString: "D0000000-0000-0000-0000-000000000004")!
    static let prowlShell = UUID(uuidString: "D0000000-0000-0000-0000-000000000005")!
    static let kingfisherShell = UUID(uuidString: "D0000000-0000-0000-0000-000000000006")!
  }

  /// The permission menu of the blocked pane.
  static let blockedPromptID = "screen:5f1d2c.1"

  /// The demo Mac: four agents in every state and two shells, in three projects.
  static func standard(now: Date = Date(), workingRunsFor: Duration = .seconds(120)) -> MirrorDemoContent {
    MirrorDemoContent(
      hostName: String(localized: "Demo Mac"),
      panes: [
        blockedPane(now: now), workingPane(now: now, runsFor: workingRunsFor), donePane(now: now), idlePane(now: now),
      ] + shellPanes(now: now),
      profiles: [
        Profile(id: "claude", name: "Claude Code", runtime: "claude"),
        Profile(id: "codex", name: "Codex", runtime: "codex"),
      ])
  }

  private static let root = "/Users/demo/Projects"
  private static let prowl = Worktree(name: "main", path: "\(root)/Prowl", rootPath: "\(root)/Prowl")
  private static let kingfisher = Worktree(name: "main", path: "\(root)/Kingfisher", rootPath: "\(root)/Kingfisher")
  private static let kingfisherRelease = Worktree(
    name: "release/8.4", path: "\(root)/Kingfisher-8.4", rootPath: "\(root)/Kingfisher")
  private static let fengNiao = Worktree(name: "main", path: "\(root)/FengNiao", rootPath: "\(root)/FengNiao")

  /// Blocked: Claude Code asks to run the tests.
  private static func blockedPane(now: Date) -> Pane {
    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    var blocked = Pane(
      id: PaneID.blocked, tab: "Fix flaky prefetch test", project: "Kingfisher", color: "blue", order: 1,
      worktree: kingfisher, agent: "claude")
    let testCommand = "scripts/repeat-tests.sh 50 ImagePrefetcherTests"
    blocked.append(
      [
        .demo(
          .sessionStarted,
          .session(.init(id: "7c1e0f52-demo", cwd: kingfisher.path, model: "claude-opus-5-5")), at: ago(9)),
        .demo(.turnStarted, .turn(.init(origin: .human)), at: ago(9)),
        .demo(
          .userMessage,
          .message(
            .init(
              text: .init(
                "ImagePrefetcherTests.testPrefetchCompletesAllSources fails about once in ten CI runs. "
                  + "Find out why and fix it."
              ), origin: .human)), at: ago(9)),
        .demo(.agentStatus, .status(.init(state: .working)), source: .osc, at: ago(9)),
        .demo(.assistantReasoning, .reasoning(.init(durationMs: 4200)), at: ago(8.9)),
        .demo(
          .assistantMessage,
          .message(
            .init(text: .init("I'll read the test first, then the prefetcher's completion path."), phase: .commentary)),
          at: ago(8.8)),
      ]
        + tool(
          .init(
            id: "k1", name: "Read", kind: .read, title: "Read the test",
            path: "Tests/KingfisherTests/ImagePrefetcherTests.swift"), output: "Read 212 lines", at: ago(8.7))
        + tool(
          .init(id: "k2", name: "Grep", kind: .search, title: "pendingSources in Sources/"),
          output: "Found 6 matches in 2 files", at: ago(8.5))
        + tool(
          .init(
            id: "k3", name: "Read", kind: .read, title: "Read the prefetcher",
            path: "Sources/Networking/ImagePrefetcher.swift"), output: "Read 431 lines", at: ago(8.3)), at: ago(9))
    blocked.append(
      [
        .demo(.assistantReasoning, .reasoning(.init(durationMs: 6100)), at: ago(7.9)),
        .demo(
          .assistantMessage,
          .message(
            .init(
              text: .init(
                """
                Found it. `handleComplete(for:)` removes the finished source under `lock`, but it reads \
                `pendingSources.isEmpty` after the lock is released. When the last two sources finish at the same \
                time, both can see a set that is not empty yet, so the completion handler never runs and the test \
                times out.

                I'll make the check part of the same critical section.
                """), phase: .commentary)), at: ago(7.8)),
      ]
        + editTool(
          "k4", path: "Sources/Networking/ImagePrefetcher.swift",
          diff: """
            @@ -214,9 +214,10 @@ extension ImagePrefetcher {
                 func handleComplete(for source: Source) {
            -        lock.lock()
            -        pendingSources.remove(source)
            -        lock.unlock()
            -        if pendingSources.isEmpty { reportCompletion() }
            +        let finished: Bool = lock.withLock {
            +            pendingSources.remove(source)
            +            return pendingSources.isEmpty
            +        }
            +        if finished { reportCompletion() }
                 }
            """, at: ago(7.2))
        + [
          .demo(
            .assistantMessage,
            .message(
              .init(
                text: .init("Now I'll run the prefetcher tests 50 times to make sure the failure is gone."),
                phase: .commentary)),
            at: ago(2.2)),
          .demo(
            .toolStarted,
            .toolStart(
              .init(
                id: "k5", name: "Bash", kind: .shell, title: "Run the tests 50 times", command: testCommand)),
            at: ago(2.1)),
          .demo(.agentStatus, .status(.init(state: .blocked, kind: "permission")), source: .osc, at: ago(2)),
          .demo(.promptOpened, .prompt(testRunPrompt(testCommand)), source: .screen, at: ago(2)),
        ], at: ago(8))
    blocked.answers = [
      "1": allowedTestRun(), "2": allowedTestRun(),
      "*": declinedTestRun(),
    ]
    return blocked
  }

  /// Claude Code's permission menu for the test run, as the Host reads it from the screen.
  private static func testRunPrompt(_ command: String) -> MirrorConversationEvent.Prompt {
    .init(
      id: blockedPromptID, kind: .permission, title: "Do you want to proceed?",
      detail: .init("Bash command\n\(command)\nRun the prefetcher tests 50 times"),
      choices: [
        .init(id: "1", label: "Yes"),
        .init(id: "2", label: "Yes, and don't ask again for scripts/repeat-tests.sh commands in \(kingfisher.path)"),
        .init(id: "3", label: "No, and tell Claude what to do differently (esc)"),
      ], freeform: false)
  }

  /// What follows when the person declines the test run.
  private static func declinedTestRun() -> [Step] {
    [
      Step(
        after: .zero,
        [
          .demo(
            .toolCompleted,
            .toolEnd(.init(id: "k5", name: "Bash", status: .error, output: .init("The user declined this command."))))
        ]),
      Step(
        after: .seconds(1),
        [
          .demo(
            .assistantMessage,
            .message(
              .init(
                text: .init(
                  "Okay, I won't run the tests. The fix is in `Sources/Networking/ImagePrefetcher.swift`. "
                    + "How do you want to check it?"
                ), phase: .final))),
          .demo(.turnCompleted, .turn(.init(origin: .human, status: .completed))),
          .demo(.agentStatus, .status(.init(state: .idle)), source: .osc),
        ]),
    ]
  }

  /// What follows when the person allows the test run.
  private static func allowedTestRun() -> [Step] {
    [
      Step(after: .zero, [.demo(.agentStatus, .status(.init(state: .working)), source: .osc)]),
      Step(
        after: .seconds(3),
        [
          .demo(
            .toolCompleted,
            .toolEnd(
              .init(
                id: "k5", name: "Bash", status: .succeeded, exitCode: 0,
                output: .init(
                  """
                  Test Suite 'ImagePrefetcherTests' passed.
                  \t Executed 7 tests, with 0 failures (0 unexpected) in 0.841 seconds
                  50 runs, 350 tests, 0 failures
                  """), durationMs: 41_800)))
        ]),
      Step(after: .seconds(1.2), [.demo(.assistantReasoning, .reasoning(.init(durationMs: 1800)))]),
      Step(
        after: .seconds(1.5),
        [
          .demo(
            .assistantMessage,
            .message(
              .init(
                text: .init(
                  """
                  The flaky failure is fixed.

                  - **Cause:** `handleComplete(for:)` checked `pendingSources.isEmpty` outside the lock, so two \
                  sources that finished together could both miss the last completion.
                  - **Fix:** the removal and the check now run in one `lock.withLock` block in \
                  `Sources/Networking/ImagePrefetcher.swift`.
                  - **Check:** 50 runs of `ImagePrefetcherTests`, 350 tests, no failures. Before the change it \
                  failed 6 times in 50 runs.
                  """), phase: .final))),
          .demo(.turnCompleted, .turn(.init(origin: .human, status: .completed, durationMs: 512_000))),
          .demo(.agentStatus, .status(.init(state: .idle)), source: .osc),
        ]),
    ]
  }

  /// Working: Codex scans for unused images until `runsFor` passes.
  private static func workingPane(now: Date, runsFor workingRunsFor: Duration) -> Pane {
    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    var working = Pane(
      id: PaneID.working, tab: "Scan unused images", project: "FengNiao", color: "purple", order: 2,
      worktree: fengNiao, agent: "codex")
    working.append(
      [
        .demo(.sessionStarted, .session(.init(id: "019a-demo-fengniao", cwd: fengNiao.path)), at: ago(4)),
        .demo(.turnStarted, .turn(.init(origin: .human)), at: ago(4)),
        .demo(
          .userMessage,
          .message(
            .init(
              text: .init(
                "Find image assets that no Swift, Objective-C, or storyboard file uses. "
                  + "List them with their sizes, largest first. Don't delete anything."
              ), origin: .human)), at: ago(4)),
        .demo(.agentStatus, .status(.init(state: .working)), source: .osc, at: ago(4)),
        .demo(.assistantReasoning, .reasoning(.init(durationMs: 2600)), at: ago(3.9)),
        .demo(
          .assistantMessage,
          .message(
            .init(
              text: .init(
                "I'll count the assets first, then search the sources for each name, including names built at run time."
              ), phase: .commentary)), at: ago(3.8)),
      ]
        + tool(
          .init(
            id: "f1", name: "Shell", kind: .shell, title: "Count image assets",
            command: "fd -e png -e jpg -e pdf . Resources | wc -l"), output: "1284", at: ago(3.6))
        + tool(
          .init(
            id: "f2", name: "Shell", kind: .shell, title: "Find image names built at run time",
            command: #"rg -n 'UIImage\(named: "[^"]*\\\(' Sources"#),
          output: #"Sources/Onboarding/PageView.swift:41:    UIImage(named: "onboarding-\(index)")"#, at: ago(3.2))
        + [
          .demo(
            .assistantMessage,
            .message(
              .init(
                text: .init(
                  "`onboarding-1` to `onboarding-4` are loaded by a built name, so I'll keep them. Now the full scan."),
                phase: .commentary)), at: ago(3)),
          .demo(
            .toolStarted,
            .toolStart(
              .init(
                id: "f3", name: "Shell", kind: .shell, title: "Scan the sources for unused assets",
                command: "fengniao --list-only --exclude Pods Carthage")), at: ago(2.9)),
        ], at: ago(4))
    working.autoplay = [
      Step(
        after: workingRunsFor,
        [
          .demo(
            .toolCompleted,
            .toolEnd(
              .init(
                id: "f3", name: "Shell", status: .succeeded, exitCode: 0,
                output: .init("Searching unused files... done\n6 unused files found (4.3 MB)"), durationMs: 301_000)))
        ]),
      Step(
        after: .seconds(1.5),
        [
          .demo(
            .assistantMessage,
            .message(
              .init(
                text: .init(
                  """
                  I found 6 image assets that nothing uses, 4.3 MB in total. I did not delete anything.

                  | Asset | Size | Last changed |
                  | --- | --- | --- |
                  | `promo-banner-2025@3x.png` | 1.9 MB | 14 months ago |
                  | `legacy-splash.pdf` | 1.1 MB | 2 years ago |
                  | `tab-discover-old@2x.png` | 512 KB | 9 months ago |
                  | `badge-beta.imageset` | 384 KB | 11 months ago |
                  | `empty-state-search@3x.png` | 290 KB | 7 months ago |
                  | `icon-share-legacy.pdf` | 96 KB | 2 years ago |

                  `onboarding-1` to `onboarding-4` look unused, but `Sources/Onboarding/PageView.swift` loads them \
                  by a built name, so they are not in the list.

                  To remove these files, run `fengniao --exclude Pods Carthage` and confirm the list.
                  """), phase: .final))),
          .demo(.turnCompleted, .turn(.init(origin: .human, status: .completed, durationMs: 420_000))),
          .demo(.agentStatus, .status(.init(state: .idle)), source: .osc),
        ]),
    ]
    return working
  }

  /// Done: Codex drafted the release notes.
  private static func donePane(now: Date) -> Pane {
    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    var done = Pane(
      id: PaneID.done, tab: "Draft 8.4 release notes", project: "Kingfisher", color: "blue", order: 1,
      worktree: kingfisherRelease, agent: "codex")
    done.append(
      [
        .demo(.sessionStarted, .session(.init(id: "019a-demo-kingfisher", cwd: kingfisherRelease.path)), at: ago(14)),
        .demo(.turnStarted, .turn(.init(origin: .human)), at: ago(14)),
        .demo(
          .userMessage,
          .message(
            .init(
              text: .init(
                "Draft the release notes for 8.4.0 from the pull requests merged since 8.3.2. Use the CHANGELOG format."
              ), origin: .human)), at: ago(14)),
        .demo(.agentStatus, .status(.init(state: .working)), source: .osc, at: ago(14)),
        .demo(.assistantReasoning, .reasoning(.init(durationMs: 1900)), at: ago(13.9)),
      ]
        + tool(
          .init(
            id: "r1", name: "Shell", kind: .shell, title: "List merged pull requests",
            command: "git log --merges --oneline 8.3.2..HEAD"),
          output: """
            a41c9e2 Merge pull request #2398 from fix/prefetch-cancel
            7b0d1f3 Merge pull request #2391 from feature/prefetch-progress
            2c88e04 Merge pull request #2386 from fix/gif-frame-duration
            9e13a5b Merge pull request #2380 from feature/visionos-memory-cache
            """, at: ago(13.7))
        + tool(
          .init(id: "r2", name: "Read", kind: .read, title: "Read the changelog", path: "CHANGELOG.md"),
          output: "Read 80 lines", at: ago(13.2))
        + [
          .demo(
            .assistantMessage,
            .message(
              .init(
                text: .init(
                  """
                  Here are the notes, in the format of `CHANGELOG.md`:

                  ## 8.4.0

                  #### Add
                  - `ImagePrefetcher` reports the progress of each source. #2391
                  - On visionOS, the memory cache follows the system's memory warnings. #2380

                  #### Fix
                  - Cancelling a prefetch no longer leaves its sources in the pending list. #2398
                  - Animated GIFs with a frame duration of zero play at 10 frames per second, as browsers do. #2386

                  Should I add them to the top of `CHANGELOG.md`?
                  """), phase: .final)), at: ago(6)),
          .demo(.turnCompleted, .turn(.init(origin: .human, status: .completed, durationMs: 482_000)), at: ago(6)),
          .demo(.agentStatus, .status(.init(state: .idle)), source: .osc, at: ago(6)),
        ], at: ago(14))
    return done
  }

  /// Idle: Claude Code reviewed a branch a while ago.
  private static func idlePane(now: Date) -> Pane {
    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    var idle = Pane(
      id: PaneID.idle, tab: "Review sidebar groups", project: "Prowl", color: "mint", order: 0, worktree: prowl,
      agent: "claude")
    idle.append(
      [
        .demo(
          .sessionStarted, .session(.init(id: "3b9d77a0-demo", cwd: prowl.path, model: "claude-opus-5-5")),
          at: ago(58)),
        .demo(.turnStarted, .turn(.init(origin: .human)), at: ago(58)),
        .demo(
          .userMessage,
          .message(
            .init(
              text: .init(
                "Review the sidebar groups change on this branch. Focus on drag-and-drop edge cases. Don't edit files."
              ), origin: .human)), at: ago(58)),
        .demo(.agentStatus, .status(.init(state: .working)), source: .osc, at: ago(58)),
      ]
        + tool(
          .init(
            id: "p1", name: "Bash", kind: .shell, title: "Show the changed files",
            command: "git diff --stat origin/main...HEAD"),
          output: """
             App/Sources/Features/Sidebar/SidebarLayout.swift       | 142 ++++++++++----
             App/Sources/Features/Sidebar/SidebarDropDelegate.swift |  88 +++++++--
             App/Tests/Sidebar/SidebarLayoutTests.swift             | 121 ++++++++++++
             3 files changed, 301 insertions(+), 50 deletions(-)
            """, at: ago(57.5))
        + tool(
          .init(
            id: "p2", name: "Read", kind: .read, title: "Read the layout",
            path: "App/Sources/Features/Sidebar/SidebarLayout.swift"), output: "Read 388 lines", at: ago(57))
        + tool(
          .init(
            id: "p3", name: "Read", kind: .read, title: "Read the drop delegate",
            path: "App/Sources/Features/Sidebar/SidebarDropDelegate.swift"), output: "Read 204 lines", at: ago(56.5))
        + [
          .demo(.assistantReasoning, .reasoning(.init(durationMs: 9000)), at: ago(56)),
          .demo(
            .assistantMessage,
            .message(
              .init(
                text: .init(
                  """
                  I found two problems and one smaller point.

                  | # | Severity | Finding | Where |
                  | --- | --- | --- | --- |
                  | 1 | High | Dropping a group on its own repository removes it. | `SidebarDropDelegate.swift:132` |
                  | 2 | Medium | A drop below the last group lands inside it. | `SidebarLayout.swift:217` |
                  | 3 | Low | `move(_:to:)` saves the layout once for each moved item. | `SidebarLayout.swift:164` |

                  For the first one, refuse the drop when the target is inside the dragged group:

                  ```swift
                  guard !layout.contains(target, inGroup: dragged) else {
                    return DropProposal(operation: .forbidden)
                  }
                  ```

                  The tests cover reordering, but not drops into a group's own repositories. I'd add one test for \
                  each of the first two cases.
                  """), phase: .final)), at: ago(41)),
          .demo(.turnCompleted, .turn(.init(origin: .human, status: .completed, durationMs: 1_020_000)), at: ago(41)),
          .demo(.agentStatus, .status(.init(state: .idle)), source: .osc, at: ago(41)),
        ], at: ago(58))
    // Looked at on the Mac already, so idle rather than done.
    idle.descriptor.displayState = .idle
    return idle
  }

  /// Two shells.
  private static func shellPanes(now: Date) -> [Pane] {
    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    var prowlShell = Pane(
      id: PaneID.prowlShell, tab: "zsh", project: "Prowl", color: "mint", order: 0, worktree: prowl, agent: nil)
    prowlShell.setShellLines([
      shellPrompt(prowl) + "git status --short",
      " M App/Sources/Features/Sidebar/SidebarLayout.swift",
      " M App/Sources/Features/Sidebar/SidebarDropDelegate.swift",
      shellPrompt(prowl) + "git log --oneline -3",
      "4f2a91c Keep the group order when a repository moves",
      "b81e0d7 Add sidebar group colors",
      "1c5f3a8 Update the changelog",
      shellPrompt(prowl),
    ])
    prowlShell.descriptor.stateChangedAt = MirrorConversationEvent.formatTimestamp(ago(90))

    var kingfisherShell = Pane(
      id: PaneID.kingfisherShell, tab: "swift test", project: "Kingfisher", color: "blue", order: 1,
      worktree: kingfisher, agent: nil)
    kingfisherShell.setShellLines([
      shellPrompt(kingfisher) + "swift test --parallel",
      "Building for debugging...",
      "[312/312] Linking KingfisherPackageTests",
      "Build complete! (38.21s)",
      "Test Suite 'All tests' started.",
      "Test Suite 'All tests' passed.",
      "\t Executed 1046 tests, with 0 failures (0 unexpected) in 42.784 seconds",
      shellPrompt(kingfisher),
    ])
    kingfisherShell.descriptor.stateChangedAt = MirrorConversationEvent.formatTimestamp(ago(30))
    return [prowlShell, kingfisherShell]
  }

  /// A finished tool call: its start and its end.
  private static func tool(
    _ start: MirrorConversationEvent.ToolStart, output: String, at date: Date
  ) -> [MirrorConversationEvent] {
    [
      .demo(
        .toolStarted, .toolStart(start), at: date),
      .demo(
        .toolCompleted,
        .toolEnd(
          .init(
            id: start.id, name: start.name, status: .succeeded, exitCode: start.kind == .shell ? 0 : nil,
            output: .init(output),
            durationMs: 900)), at: date.addingTimeInterval(1)),
    ]
  }

  private static func editTool(_ id: String, path: String, diff: String, at date: Date) -> [MirrorConversationEvent] {
    [
      .demo(
        .toolStarted,
        .toolStart(
          .init(
            id: id, name: "Edit", kind: .edit, title: "Edit \(URL(fileURLWithPath: path).lastPathComponent)",
            path: path, changedPaths: [path])),
        at: date),
      .demo(
        .toolCompleted, .toolEnd(.init(id: id, name: "Edit", status: .succeeded, diff: .init(diff), durationMs: 300)),
        at: date.addingTimeInterval(1)),
    ]
  }
}
