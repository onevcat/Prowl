import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CLIListCommandHandlerTests {

  @Test func buildsSchemaConformantListPayloadInStableOrder() async throws {
    let handler = ListCommandHandler {
      ListRuntimeSnapshot(
        worktrees: [
          .init(
            id: "Prowl:/Users/onevcat/Projects/Prowl",
            name: "Prowl",
            path: "/Users/onevcat/Projects/Prowl",
            rootPath: "/Users/onevcat/Projects/Prowl",
            kind: .git,
            taskStatus: .running,
            tabs: [
              .init(
                id: UUID(uuidString: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0")!,
                handle: 1,
                title: "Prowl 1",
                selected: true,
                focusedPaneID: UUID(uuidString: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764")!,
                panes: [
                  .init(
                    id: UUID(uuidString: "1344AEF5-3BA6-4B75-A07E-1F36C63A34B0")!,
                    handle: 2,
                    title: "tests",
                    cwd: "/Users/onevcat/Projects/Prowl",
                    agent: "codex"
                  ),
                  .init(
                    id: UUID(uuidString: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764")!,
                    handle: 3,
                    title: "build",
                    cwd: "/Users/onevcat/Projects/Prowl",
                    agent: nil
                  ),
                ]
              )
            ]
          ),
          .init(
            id: "Notes:/Users/onevcat/Projects/Notes",
            name: "Notes",
            path: "/Users/onevcat/Projects/Notes",
            rootPath: "/Users/onevcat/Projects/Notes",
            kind: .plain,
            taskStatus: .idle,
            tabs: [
              .init(
                id: UUID(uuidString: "A2B07BBA-9DD0-4C77-9D76-2B3E0AF12096")!,
                handle: 4,
                title: "Notes",
                selected: true,
                focusedPaneID: UUID(uuidString: "EF65FF31-1B72-40B2-80DA-3AA87B7B6858")!,
                panes: [
                  .init(
                    id: UUID(uuidString: "EF65FF31-1B72-40B2-80DA-3AA87B7B6858")!,
                    handle: 5,
                    title: "notes",
                    cwd: "/Users/onevcat/Projects/Notes",
                    agent: nil
                  )
                ]
              )
            ]
          ),
        ],
        focusedWorktreeID: "Prowl:/Users/onevcat/Projects/Prowl"
      )
    }

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .list(ListInput()))
    )

    #expect(response.ok)
    #expect(response.command == "list")
    #expect(response.schemaVersion == "prowl.cli.list.v1")

    let payload = try #require(try response.data?.decode(as: ListCommandPayload.self))
    #expect(payload.count == 3)
    #expect(payload.items.count == 3)

    // Stable order: worktree order -> tab order -> pane order
    #expect(payload.items[0].worktree.id == "Prowl:/Users/onevcat/Projects/Prowl")
    #expect(payload.items[0].pane.id == "1344AEF5-3BA6-4B75-A07E-1F36C63A34B0")
    #expect(payload.items[1].pane.id == "6E1A2A10-D99F-4E3F-920C-D93AA3C05764")
    #expect(payload.items[2].worktree.id == "Notes:/Users/onevcat/Projects/Notes")

    let focusedItems = payload.items.filter(\.pane.focused)
    #expect(focusedItems.count == 1)
    #expect(focusedItems.first?.pane.id == "6E1A2A10-D99F-4E3F-920C-D93AA3C05764")

    #expect(payload.items[0].task.status == .running)
    #expect(payload.items[2].task.status == .idle)
    #expect(payload.items[0].pane.agent == "codex")
    #expect(payload.items[1].pane.agent == nil)
    #expect(payload.items.allSatisfy { $0.tab.handle == nil && $0.pane.handle == nil })
    let rawPayload = try #require(response.data?.bytes)
    let rawPayloadString = try #require(String(bytes: rawPayload, encoding: .utf8))
    #expect(!rawPayloadString.contains("\"handle\""))
  }

  @Test func includesShortHandlesInTextPayload() async throws {
    let tabID = UUID()
    let paneID = UUID()
    let handler = ListCommandHandler {
      ListRuntimeSnapshot(
        worktrees: [
          .init(
            id: "worktree",
            name: "main",
            path: "/tmp/worktree",
            rootPath: "/tmp/worktree",
            kind: .git,
            taskStatus: .idle,
            tabs: [
              .init(
                id: tabID,
                handle: 12,
                title: "Tab",
                selected: true,
                focusedPaneID: paneID,
                panes: [.init(id: paneID, handle: 13, title: "shell", cwd: "/tmp/worktree")]
              )
            ]
          )
        ],
        focusedWorktreeID: "worktree"
      )
    }

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .text, command: .list(ListInput()))
    )
    let payload = try #require(try response.data?.decode(as: ListCommandPayload.self))

    #expect(payload.items[0].tab.id == tabID.uuidString)
    #expect(payload.items[0].tab.handle == 12)
    #expect(payload.items[0].pane.id == paneID.uuidString)
    #expect(payload.items[0].pane.handle == 13)
  }

  @Test func returnsListFailedWhenSnapshotProviderThrows() async {
    struct DummyError: Error {}

    let handler = ListCommandHandler {
      throw DummyError()
    }

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .list(ListInput()))
    )

    #expect(response.ok == false)
    #expect(response.command == "list")
    #expect(response.schemaVersion == "prowl.cli.list.v1")
    #expect(response.error?.code == CLIErrorCode.listFailed)
  }
}
