import ComposableArchitecture
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct WorkflowRoleBadgeTests {
  @Test func activeRunPanesWearTheirRoleBadge() throws {
    let definition = try #require(
      WorkflowDocumentParser.parse(WorkflowStartContextTests.autoFlow).definition)
    let authorPane = WorkflowPaneIdentity(
      surfaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      tabID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
      handle: "p1", displayName: "Claude Code", agent: "claude")
    let started = try WorkflowRunMachine.start(
      WorkflowRunStartRequest(
        definition: definition,
        runID: UUID(uuidString: "0BADCAFE-0000-4000-8000-000000000042")!,
        context: WorkflowRunContext(
          scope: .user, definitionPath: "/tmp/auto.yaml",
          worktree: WorkflowRunWorktree(id: "/tmp/repo/wt", name: "wt", branch: "main", path: "/tmp/repo/wt")),
        bindings: [
          "author": .current(authorPane),
          "reviewer": .launch(
            WorkflowProfileBinding(
              id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
              name: "Pi Reviewer", agent: "pi"),
            pane: nil),
        ],
        inputs: [:],
        skippedSteps: [],
        selfInitiated: false),
      now: { Date(timeIntervalSince1970: 1_760_000_000) },
      makeToken: { "TOKEN" })
    let session = WorkflowRunSession(
      run: started.machine.run,
      worktree: Worktree(
        id: "/tmp/repo/wt", name: "wt", detail: "detail",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")),
      launchPlans: [:], bindingMemoryKeys: [:], skills: [:])

    var runs = WorkflowRunsFeature.State()
    runs.sessions[session.run.id] = session

    let badges = AppFeature.workflowRoleBadges(for: runs)
    #expect(badges == [authorPane.surfaceID: "in Auto Flow \u{00B7} author"])
  }
}
