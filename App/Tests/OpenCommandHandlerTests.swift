// supacodeTests/OpenCommandHandlerTests.swift
// Unit tests for OpenCommandHandler — contract-aligned.

import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct OpenCommandHandlerTests {

  @MainActor
  final class MutableBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
      self.value = value
    }
  }

  // MARK: - Helpers

  private func makeResolvedTarget(
    worktreeID: String = "Prowl:/Users/test/Projects/Prowl",
    worktreeName: String = "Prowl",
    worktreePath: String = "/Users/test/Projects/Prowl",
    worktreeRootPath: String = "/Users/test/Projects/Prowl",
    worktreeKind: String = "git",
    tabID: String = "0E2A7C03-9C01-4BC1-9327-6C1C7B629A52",
    tabTitle: String = "Prowl 1",
    tabCWD: String? = "/Users/test/Projects/Prowl",
    paneID: String = "0FB4DDB4-A797-4315-A00E-8AAFB32BFC95",
    paneTitle: String = "Prowl",
    paneCWD: String? = "/Users/test/Projects/Prowl"
  ) -> OpenResolvedTarget {
    OpenResolvedTarget(
      worktreeID: worktreeID,
      worktreeName: worktreeName,
      worktreePath: worktreePath,
      worktreeRootPath: worktreeRootPath,
      worktreeKind: worktreeKind,
      tabID: tabID,
      tabTitle: tabTitle,
      tabCWD: tabCWD,
      paneID: paneID,
      paneTitle: paneTitle,
      paneCWD: paneCWD
    )
  }

  private func makeHandler(
    resolver: @escaping OpenCommandHandler.Resolver = { _ in
      OpenResolverResult(
        resolution: .noArgument, worktreeID: nil, worktreeName: nil,
        worktreePath: nil, rootPath: nil, worktreeKind: nil, resolvedPath: nil
      )
    },
    selectWorktree: @escaping OpenCommandHandler.SelectAction = { _ in },
    addAndOpen: @escaping OpenCommandHandler.AddAndOpenAction = { _ in },
    createTabAtPath: @escaping OpenCommandHandler.CreateTabAtPathAction = { _, _ in },
    resolveTarget: @escaping OpenCommandHandler.ResolveTargetAction = { selector in
      switch selector {
      case .none:
        return OpenResolvedTarget(
          worktreeID: "Prowl:/Users/test/Projects/Prowl",
          worktreeName: "Prowl",
          worktreePath: "/Users/test/Projects/Prowl",
          worktreeRootPath: "/Users/test/Projects/Prowl",
          worktreeKind: "git",
          tabID: "0E2A7C03-9C01-4BC1-9327-6C1C7B629A52",
          tabTitle: "Prowl 1",
          tabCWD: "/Users/test/Projects/Prowl",
          paneID: "0FB4DDB4-A797-4315-A00E-8AAFB32BFC95",
          paneTitle: "Prowl",
          paneCWD: "/Users/test/Projects/Prowl"
        )
      case .worktree(let value):
        return OpenResolvedTarget(
          worktreeID: value,
          worktreeName: "Prowl",
          worktreePath: "/Users/test/Projects/Prowl",
          worktreeRootPath: "/Users/test/Projects/Prowl",
          worktreeKind: "git",
          tabID: "0E2A7C03-9C01-4BC1-9327-6C1C7B629A52",
          tabTitle: "Prowl 1",
          tabCWD: "/Users/test/Projects/Prowl",
          paneID: "0FB4DDB4-A797-4315-A00E-8AAFB32BFC95",
          paneTitle: "Prowl",
          paneCWD: "/Users/test/Projects/Prowl"
        )
      default:
        return nil
      }
    },
    isRepositoriesReady: @escaping OpenCommandHandler.ReadinessProvider = { true },
    sleep: @escaping OpenCommandHandler.SleepAction = { _ in },
    waitTimeoutNanoseconds: UInt64 = 1_000_000
  ) -> OpenCommandHandler {
    OpenCommandHandler(
      resolver: resolver,
      selectWorktree: selectWorktree,
      addAndOpen: addAndOpen,
      createTabAtPath: createTabAtPath,
      resolveTarget: resolveTarget,
      isRepositoriesReady: isRepositoriesReady,
      sleep: sleep,
      waitTimeoutNanoseconds: waitTimeoutNanoseconds,
      pollIntervalNanoseconds: 1
    )
  }

  private func jsonObject(from response: CommandResponse) throws -> [String: Any] {
    let data = try #require(response.data)
    return try #require(JSONSerialization.jsonObject(with: data.bytes) as? [String: Any])
  }

  // MARK: - Bring to front (no path)

  @MainActor
  @Test func openWithNoPathReturnsBringToFrontAndCurrentTarget() async throws {
    let handler = makeHandler()
    let envelope = CommandEnvelope(output: .json, command: .open(OpenInput()))
    let response = await handler.handle(envelope: envelope)

    #expect(response.ok == true)
    #expect(response.command == "open")
    #expect(response.schemaVersion == "prowl.cli.open.v1")

    let data = try #require(response.data)
    let payload = try data.decode(as: OpenCommandData.self)
    let target = try #require(payload.target)
    #expect(payload.resolution == "no-argument")
    #expect(payload.invocation == "bare")
    #expect(payload.requestedPath == nil)
    #expect(payload.resolvedPath == nil)
    #expect(payload.broughtToFront == true)
    #expect(payload.appLaunched == false)
    #expect(target.worktree.id == "Prowl:/Users/test/Projects/Prowl")

    let json = try jsonObject(from: response)
    #expect(json.keys.contains("requested_path"))
    #expect(json.keys.contains("resolved_path"))
    #expect(json["requested_path"] is NSNull)
    #expect(json["resolved_path"] is NSNull)
    #expect((json["target"] as? [String: Any]) != nil)
  }

  @MainActor
  @Test func openWithNoPathSucceedsEvenWhenNoFocusedSurfaceCanBeResolved() async throws {
    let handler = makeHandler(
      resolveTarget: { _ in nil }
    )

    let envelope = CommandEnvelope(output: .json, command: .open(OpenInput()))
    let response = await handler.handle(envelope: envelope)

    #expect(response.ok == true)

    let json = try jsonObject(from: response)
    #expect(json["resolution"] as? String == "no-argument")
    #expect(json["created_tab"] as? Bool == false)
    #expect(json.keys.contains("target"))
    #expect(json["target"] is NSNull)
  }

  // MARK: - No-argument regression (no spurious polling)

  @MainActor
  @Test func openWithNoPathDoesNotPollWhenNoTargetExists() async throws {
    let sleepCount = MutableBox(0)

    let handler = makeHandler(
      resolveTarget: { _ in nil },
      sleep: { _ in
        await MainActor.run { sleepCount.value += 1 }
      },
      waitTimeoutNanoseconds: 10_000_000_000
    )

    let envelope = CommandEnvelope(output: .json, command: .open(OpenInput()))
    let response = await handler.handle(envelope: envelope)

    #expect(response.ok == true)
    #expect(sleepCount.value == 0, "Bare prowl must not poll when no target exists")
  }

  // MARK: - Exact root

  @MainActor
  @Test func openExactRootSelectsAndReturnsContractPayload() async throws {
    var selectedID: String?

    let handler = makeHandler(
      resolver: { _ in
        OpenResolverResult(
          resolution: .exactRoot,
          worktreeID: "Prowl:/Users/test/Projects/Prowl",
          worktreeName: "Prowl",
          worktreePath: "/Users/test/Projects/Prowl",
          rootPath: "/Users/test/Projects/Prowl",
          worktreeKind: "git",
          resolvedPath: "/Users/test/Projects/Prowl"
        )
      },
      selectWorktree: { id in selectedID = id },
      resolveTarget: { selector in
        guard case .worktree(let value) = selector else { return nil }
        return makeResolvedTarget(worktreeID: value)
      }
    )

    let envelope = CommandEnvelope(
      output: .json,
      command: .open(OpenInput(path: "/Users/test/Projects/Prowl", invocation: "open-subcommand"))
    )
    let response = await handler.handle(envelope: envelope)

    #expect(response.ok == true)
    #expect(selectedID == "Prowl:/Users/test/Projects/Prowl")

    let exactRootData = try #require(response.data)
    let payload = try exactRootData.decode(as: OpenCommandData.self)
    let target = try #require(payload.target)
    #expect(payload.resolution == "exact-root")
    #expect(payload.invocation == "open-subcommand")
    #expect(payload.requestedPath == "/Users/test/Projects/Prowl")
    #expect(payload.resolvedPath == "/Users/test/Projects/Prowl")
    #expect(payload.createdTab == false)
    #expect(payload.broughtToFront == true)
    #expect(target.worktree.id == "Prowl:/Users/test/Projects/Prowl")
    #expect(target.tab.id == "0E2A7C03-9C01-4BC1-9327-6C1C7B629A52")
    #expect(target.pane.id == "0FB4DDB4-A797-4315-A00E-8AAFB32BFC95")

    let json = try jsonObject(from: response)
    #expect(
      Set(json.keys) == [
        "invocation", "requested_path", "resolved_path", "resolution",
        "app_launched", "brought_to_front", "created_tab", "target",
      ])
    let jsonTarget = try #require(json["target"] as? [String: Any])
    #expect(Set(jsonTarget.keys) == ["worktree", "tab", "pane"])
    let worktree = try #require(jsonTarget["worktree"] as? [String: Any])
    #expect(Set(worktree.keys) == ["id", "name", "path", "root_path", "kind"])
    let tab = try #require(jsonTarget["tab"] as? [String: Any])
    #expect(Set(tab.keys) == ["id", "title", "cwd"])
    let pane = try #require(jsonTarget["pane"] as? [String: Any])
    #expect(Set(pane.keys) == ["id", "title", "cwd"])
  }

  @MainActor
  @Test func openExactRootCreatesNewTabWhenSelectedWorktreeHasNoVisibleSurface() async throws {
    var selectedID: String?
    var createdTabFor: String?
    var createdTabAtPath: String?
    let created = MutableBox(false)
    let rootPath = "/Users/test/Projects/Prowl"

    let handler = makeHandler(
      resolver: { _ in
        OpenResolverResult(
          resolution: .exactRoot,
          worktreeID: "Prowl:/Users/test/Projects/Prowl",
          worktreeName: "Prowl",
          worktreePath: rootPath,
          rootPath: rootPath,
          worktreeKind: "git",
          resolvedPath: rootPath
        )
      },
      selectWorktree: { selectedID = $0 },
      createTabAtPath: { worktreeID, path in
        createdTabFor = worktreeID
        createdTabAtPath = path
        created.value = true
      },
      resolveTarget: { selector in
        guard created.value, case .worktree(let value) = selector else { return nil }
        return makeResolvedTarget(worktreeID: value, tabCWD: rootPath, paneCWD: rootPath)
      },
      waitTimeoutNanoseconds: 3
    )

    let envelope = CommandEnvelope(
      output: .json,
      command: .open(OpenInput(path: rootPath, invocation: "open-subcommand"))
    )
    let response = await handler.handle(envelope: envelope)

    #expect(response.ok == true)
    #expect(selectedID == "Prowl:/Users/test/Projects/Prowl")
    #expect(createdTabFor == "Prowl:/Users/test/Projects/Prowl")
    #expect(createdTabAtPath == rootPath)

    let json = try jsonObject(from: response)
    #expect(json["resolution"] as? String == "exact-root")
    #expect(json["created_tab"] as? Bool == true)
    let target = try #require(json["target"] as? [String: Any])
    let pane = try #require(target["pane"] as? [String: Any])
    #expect(pane["cwd"] as? String == rootPath)
  }

  @MainActor
  @Test func openExactRootDoesNotPollBeforeCreatingTab() async throws {
    let sleepBeforeCreate = MutableBox(0)
    let created = MutableBox(false)
    let rootPath = "/Users/test/Projects/Prowl"

    let handler = makeHandler(
      resolver: { _ in
        OpenResolverResult(
          resolution: .exactRoot,
          worktreeID: "Prowl:/Users/test/Projects/Prowl",
          worktreeName: "Prowl",
          worktreePath: rootPath,
          rootPath: rootPath,
          worktreeKind: "git",
          resolvedPath: rootPath
        )
      },
      createTabAtPath: { _, _ in
        created.value = true
      },
      resolveTarget: { selector in
        guard created.value, case .worktree(let value) = selector else { return nil }
        return makeResolvedTarget(worktreeID: value, tabCWD: rootPath, paneCWD: rootPath)
      },
      sleep: { _ in
        await MainActor.run {
          if !created.value {
            sleepBeforeCreate.value += 1
          }
        }
      },
      waitTimeoutNanoseconds: 3
    )

    let envelope = CommandEnvelope(
      output: .json,
      command: .open(OpenInput(path: rootPath, invocation: "open-subcommand"))
    )
    let response = await handler.handle(envelope: envelope)

    #expect(response.ok == true)
    #expect(sleepBeforeCreate.value == 0, "Must not poll before creating tab when worktree has no visible surface")
  }

  // MARK: - Inside root

  @MainActor
  @Test func openInsideRootSelectsWorktreeCreatesTabAndKeepsExactTargetCwd() async throws {
    var selectedID: String?
    var tabCreatedForWorktree: String?
    var tabCreatedAtPath: String?

    let subpath = "/Users/test/Projects/Prowl/supacode"

    let handler = makeHandler(
      resolver: { _ in
        OpenResolverResult(
          resolution: .insideRoot,
          worktreeID: "Prowl:/Users/test/Projects/Prowl",
          worktreeName: "Prowl",
          worktreePath: "/Users/test/Projects/Prowl",
          rootPath: "/Users/test/Projects/Prowl",
          worktreeKind: "git",
          resolvedPath: subpath
        )
      },
      selectWorktree: { id in selectedID = id },
      createTabAtPath: { worktreeID, path in
        tabCreatedForWorktree = worktreeID
        tabCreatedAtPath = path
      },
      resolveTarget: { selector in
        guard case .worktree(let value) = selector else { return nil }
        return makeResolvedTarget(worktreeID: value, tabCWD: subpath, paneCWD: subpath)
      }
    )

    let envelope = CommandEnvelope(
      output: .json,
      command: .open(OpenInput(path: subpath, invocation: "implicit-open"))
    )
    let response = await handler.handle(envelope: envelope)

    #expect(response.ok == true)
    #expect(selectedID == "Prowl:/Users/test/Projects/Prowl")
    #expect(tabCreatedForWorktree == "Prowl:/Users/test/Projects/Prowl")
    #expect(tabCreatedAtPath == subpath)

    let insideRootData = try #require(response.data)
    let payload = try insideRootData.decode(as: OpenCommandData.self)
    let target = try #require(payload.target)
    #expect(payload.resolution == "inside-root")
    #expect(payload.invocation == "implicit-open")
    #expect(payload.requestedPath == subpath)
    #expect(payload.resolvedPath == subpath)
    #expect(payload.createdTab == true)
    #expect(target.tab.cwd == subpath)
    #expect(target.pane.cwd == subpath)
  }

  // MARK: - New root

  @MainActor
  @Test func openNewRootCallsAddAndWaitsForManagedTarget() async throws {
    var addedURL: URL?
    let managed = MutableBox(false)

    let handler = makeHandler(
      resolver: { _ in
        if managed.value {
          return OpenResolverResult(
            resolution: .exactRoot,
            worktreeID: "NewProject:/Users/test/NewProject",
            worktreeName: "NewProject",
            worktreePath: "/Users/test/NewProject",
            rootPath: "/Users/test/NewProject",
            worktreeKind: "git",
            resolvedPath: "/Users/test/NewProject"
          )
        }
        return OpenResolverResult(
          resolution: .newRoot,
          worktreeID: nil,
          worktreeName: nil,
          worktreePath: nil,
          rootPath: nil,
          worktreeKind: nil,
          resolvedPath: "/Users/test/NewProject"
        )
      },
      addAndOpen: { url in addedURL = url },
      resolveTarget: { selector in
        guard managed.value, case .worktree(let value) = selector else { return nil }
        return makeResolvedTarget(
          worktreeID: value,
          worktreeName: "NewProject",
          worktreePath: "/Users/test/NewProject",
          worktreeRootPath: "/Users/test/NewProject",
          tabCWD: "/Users/test/NewProject",
          paneCWD: "/Users/test/NewProject"
        )
      },
      sleep: { _ in
        await MainActor.run {
          managed.value = true
        }
      },
      waitTimeoutNanoseconds: 3
    )

    let envelope = CommandEnvelope(
      output: .json,
      command: .open(OpenInput(path: "/Users/test/NewProject"))
    )
    let response = await handler.handle(envelope: envelope)

    #expect(response.ok == true)
    #expect(addedURL?.path == "/Users/test/NewProject")

    let newRootData = try #require(response.data)
    let payload = try newRootData.decode(as: OpenCommandData.self)
    let target = try #require(payload.target)
    #expect(payload.resolution == "new-root")
    #expect(payload.requestedPath == "/Users/test/NewProject")
    #expect(payload.createdTab == true)
    #expect(target.worktree.id == "NewProject:/Users/test/NewProject")
  }

  @MainActor
  @Test func openNewRootCreatesTabWhenRepositoryBecomesManagedWithoutVisibleSurface() async throws {
    var addedURL: URL?
    var createdTabFor: String?
    var createdTabAtPath: String?
    let managed = MutableBox(false)
    let created = MutableBox(false)
    let rootPath = "/Users/test/NewProject"
    let worktreeID = "NewProject:/Users/test/NewProject"

    let handler = makeHandler(
      resolver: { _ in
        if managed.value {
          return OpenResolverResult(
            resolution: .exactRoot,
            worktreeID: worktreeID,
            worktreeName: "NewProject",
            worktreePath: rootPath,
            rootPath: rootPath,
            worktreeKind: "git",
            resolvedPath: rootPath
          )
        }
        return OpenResolverResult(
          resolution: .newRoot,
          worktreeID: nil,
          worktreeName: nil,
          worktreePath: nil,
          rootPath: nil,
          worktreeKind: nil,
          resolvedPath: rootPath
        )
      },
      addAndOpen: { url in addedURL = url },
      createTabAtPath: { id, path in
        createdTabFor = id
        createdTabAtPath = path
        created.value = true
      },
      resolveTarget: { selector in
        guard created.value, case .worktree(let value) = selector else { return nil }
        return makeResolvedTarget(
          worktreeID: value,
          worktreeName: "NewProject",
          worktreePath: rootPath,
          worktreeRootPath: rootPath,
          tabCWD: rootPath,
          paneCWD: rootPath
        )
      },
      sleep: { _ in
        await MainActor.run {
          managed.value = true
        }
      },
      waitTimeoutNanoseconds: 3
    )

    let envelope = CommandEnvelope(
      output: .json,
      command: .open(OpenInput(path: rootPath, invocation: "implicit-open"))
    )
    let response = await handler.handle(envelope: envelope)

    #expect(response.ok == true)
    #expect(
      addedURL?.standardizedFileURL.path(percentEncoded: false)
        == URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path(percentEncoded: false)
    )
    #expect(createdTabFor == worktreeID)
    #expect(createdTabAtPath == rootPath)

    let json = try jsonObject(from: response)
    #expect(json["resolution"] as? String == "new-root")
    #expect(json["created_tab"] as? Bool == true)
    let target = try #require(json["target"] as? [String: Any])
    let pane = try #require(target["pane"] as? [String: Any])
    #expect(pane["cwd"] as? String == rootPath)
  }

  // MARK: - Readiness gating

  @MainActor
  @Test func waitsForRepositoriesReadyBeforeResolvingColdLaunchPath() async throws {
    let ready = MutableBox(false)
    var selectedID: String?
    var addAndOpenCalled = false

    let handler = makeHandler(
      resolver: { _ in
        if ready.value {
          return OpenResolverResult(
            resolution: .exactRoot,
            worktreeID: "Prowl:/Users/test/Projects/Prowl",
            worktreeName: "Prowl",
            worktreePath: "/Users/test/Projects/Prowl",
            rootPath: "/Users/test/Projects/Prowl",
            worktreeKind: "git",
            resolvedPath: "/Users/test/Projects/Prowl"
          )
        }
        return OpenResolverResult(
          resolution: .newRoot,
          worktreeID: nil,
          worktreeName: nil,
          worktreePath: nil,
          rootPath: nil,
          worktreeKind: nil,
          resolvedPath: "/Users/test/Projects/Prowl"
        )
      },
      selectWorktree: { selectedID = $0 },
      addAndOpen: { _ in addAndOpenCalled = true },
      resolveTarget: { selector in
        guard ready.value, case .worktree(let value) = selector else { return nil }
        return makeResolvedTarget(worktreeID: value)
      },
      isRepositoriesReady: { ready.value },
      sleep: { _ in
        await MainActor.run {
          ready.value = true
        }
      },
      waitTimeoutNanoseconds: 10_000
    )

    let envelope = CommandEnvelope(
      output: .json,
      command: .open(OpenInput(path: "/Users/test/Projects/Prowl", appLaunched: true))
    )
    let response = await handler.handle(envelope: envelope)

    #expect(response.ok == true)
    #expect(addAndOpenCalled == false)
    #expect(selectedID == "Prowl:/Users/test/Projects/Prowl")

    let readinessData = try #require(response.data)
    let payload = try readinessData.decode(as: OpenCommandData.self)
    #expect(payload.resolution == "exact-root")
    #expect(payload.appLaunched == true)
  }

  // MARK: - Router integration

  @MainActor
  @Test func routerUsesInjectedOpenHandler() async throws {
    let handler = makeHandler()
    let router = CLICommandRouter(openHandler: handler)
    let envelope = CommandEnvelope(output: .json, command: .open(OpenInput()))
    let response = await router.route(envelope)

    #expect(response.ok == true)
    #expect(response.command == "open")
    #expect(response.schemaVersion == "prowl.cli.open.v1")
  }

  // MARK: - Wrong command type

  @MainActor
  @Test func handlerRejectsNonOpenCommand() async {
    let handler = makeHandler()
    let envelope = CommandEnvelope(output: .json, command: .list(ListInput()))
    let response = await handler.handle(envelope: envelope)

    #expect(response.ok == false)
    #expect(response.error?.code == "INVALID_ARGUMENT")
  }

  // MARK: - Invocation derivation

  @MainActor
  @Test func defaultInvocationIsOpenSubcommandWhenPathPresent() async throws {
    let managed = MutableBox(false)
    let handler = makeHandler(
      resolver: { _ in
        if managed.value {
          return OpenResolverResult(
            resolution: .exactRoot,
            worktreeID: "test:/tmp/test",
            worktreeName: "test",
            worktreePath: "/tmp/test",
            rootPath: "/tmp/test",
            worktreeKind: "git",
            resolvedPath: "/tmp/test"
          )
        }
        return OpenResolverResult(
          resolution: .newRoot,
          worktreeID: nil,
          worktreeName: nil,
          worktreePath: nil,
          rootPath: nil,
          worktreeKind: nil,
          resolvedPath: "/tmp/test"
        )
      },
      resolveTarget: { selector in
        guard managed.value, case .worktree(let value) = selector else { return nil }
        return makeResolvedTarget(
          worktreeID: value,
          worktreeName: "test",
          worktreePath: "/tmp/test",
          worktreeRootPath: "/tmp/test",
          tabCWD: "/tmp/test",
          paneCWD: "/tmp/test"
        )
      },
      sleep: { _ in
        await MainActor.run {
          managed.value = true
        }
      },
      waitTimeoutNanoseconds: 3
    )
    let envelope = CommandEnvelope(output: .json, command: .open(OpenInput(path: "/tmp/test")))
    let response = await handler.handle(envelope: envelope)
    let invocationData = try #require(response.data)
    let payload = try invocationData.decode(as: OpenCommandData.self)
    #expect(payload.invocation == "open-subcommand")
  }

  @MainActor
  @Test func explicitInvocationIsPreserved() async throws {
    let handler = makeHandler(
      resolver: { _ in
        OpenResolverResult(
          resolution: .insideRoot,
          worktreeID: "Prowl:/tmp/test",
          worktreeName: "test",
          worktreePath: "/tmp/test",
          rootPath: "/tmp/test",
          worktreeKind: "git",
          resolvedPath: "/tmp/test/subdir"
        )
      },
      resolveTarget: { selector in
        guard case .worktree(let value) = selector else { return nil }
        return makeResolvedTarget(
          worktreeID: value,
          worktreeName: "test",
          worktreePath: "/tmp/test",
          worktreeRootPath: "/tmp/test",
          tabCWD: "/tmp/test/subdir",
          paneCWD: "/tmp/test/subdir"
        )
      }
    )
    let envelope = CommandEnvelope(
      output: .json,
      command: .open(OpenInput(path: "/tmp/test/subdir", invocation: "implicit-open"))
    )
    let response = await handler.handle(envelope: envelope)
    let explicitInvocationData = try #require(response.data)
    let payload = try explicitInvocationData.decode(as: OpenCommandData.self)
    #expect(payload.invocation == "implicit-open")
  }
}
