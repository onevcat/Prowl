import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CLITabCommandHandlerTests {
  @Test func createResolvesWorktreeCreatesTabAndReturnsNewTarget() async throws {
    let base = makeTarget(tabID: "base-tab", paneID: "base-pane")
    let created = makeTarget(tabID: "new-tab", tabTitle: "App 2", paneID: "new-pane", paneTitle: "zsh")
    var resolvedSelector: TargetSelector?
    var createBase: TabResolvedTarget?
    var createPath: String?

    let handler = TabCommandHandler(
      resolveProvider: { selector in
        resolvedSelector = selector
        return .success(base)
      },
      createTab: { target, path in
        createBase = target
        createPath = path
        return created
      },
      closeTab: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .tab(TabInput(action: .create, selector: .worktree("App"), path: "/Projects/App"))
      )
    )

    #expect(response.ok == true)
    #expect(response.command == "tab")
    #expect(resolvedSelector == .worktree("App"))
    #expect(createBase == base)
    #expect(createPath == "/Projects/App")

    let data = try #require(response.data)
    let payload = try data.decode(as: TabCommandPayload.self)
    #expect(payload.action == .create)
    #expect(payload.target.tab.id == "new-tab")
    #expect(payload.target.pane.id == "new-pane")
  }

  @Test func createRejectsPathOutsideResolvedWorktree() async throws {
    var didCreate = false
    let handler = TabCommandHandler(
      resolveProvider: { _ in .success(makeTarget(worktreePath: "/Projects/App")) },
      createTab: { _, _ in
        didCreate = true
        return nil
      },
      closeTab: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .tab(TabInput(action: .create, selector: .worktree("App"), path: "/Projects/Other"))
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.pathNotAllowed)
    #expect(didCreate == false)
  }

  @Test func createAllowsOmittedPath() async throws {
    var createPath: String?
    let handler = TabCommandHandler(
      resolveProvider: { _ in .success(makeTarget(worktreePath: "/Projects/App")) },
      createTab: { _, path in
        createPath = path
        return makeTarget(tabID: "created-tab", paneID: "created-pane")
      },
      closeTab: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .tab(TabInput(action: .create, selector: .none))
      )
    )

    #expect(response.ok == true)
    #expect(createPath == nil)
  }

  @Test func closeResolvesTargetAndClosesTab() async throws {
    let target = makeTarget(tabID: "tab-to-close", paneID: "pane-in-tab")
    var closedTarget: TabResolvedTarget?
    var closeForce: Bool?

    let handler = TabCommandHandler(
      resolveProvider: { selector in
        #expect(selector == .tab("tab-to-close"))
        return .success(target)
      },
      createTab: { _, _ in nil },
      closeTab: { target, force in
        closedTarget = target
        closeForce = force
        return true
      }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .tab(TabInput(action: .close, selector: .tab("tab-to-close"), force: true))
      )
    )

    #expect(response.ok == true)
    #expect(closedTarget == target)
    #expect(closeForce == true)
    let data = try #require(response.data)
    let payload = try data.decode(as: TabCommandPayload.self)
    #expect(payload.action == .close)
    #expect(payload.target.tab.id == "tab-to-close")
  }

  @Test func closeRejectsMissingExplicitTarget() async throws {
    var didResolve = false
    var didClose = false
    let handler = TabCommandHandler(
      resolveProvider: { _ in
        didResolve = true
        return .success(makeTarget())
      },
      createTab: { _, _ in nil },
      closeTab: { _, _ in
        didClose = true
        return true
      }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .tab(TabInput(action: .close, selector: .none))
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
    #expect(didResolve == false)
    #expect(didClose == false)
  }

  private func makeTarget(
    worktreeID: String = "App:/Projects/App",
    worktreeName: String = "App",
    worktreePath: String = "/Projects/App",
    worktreeRootPath: String = "/Projects/App",
    worktreeKind: String = "git",
    tabID: String = "tab-1",
    tabTitle: String = "App 1",
    tabSelected: Bool = true,
    paneID: String = "pane-1",
    paneTitle: String = "zsh",
    paneCWD: String? = "/Projects/App",
    paneFocused: Bool = true
  ) -> TabResolvedTarget {
    TabResolvedTarget(
      worktreeID: worktreeID,
      worktreeName: worktreeName,
      worktreePath: worktreePath,
      worktreeRootPath: worktreeRootPath,
      worktreeKind: worktreeKind,
      tabID: tabID,
      tabTitle: tabTitle,
      tabSelected: tabSelected,
      paneID: paneID,
      paneTitle: paneTitle,
      paneCWD: paneCWD,
      paneFocused: paneFocused
    )
  }
}
