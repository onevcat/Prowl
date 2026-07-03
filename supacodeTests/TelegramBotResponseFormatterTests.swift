import Foundation
import Testing

@testable import supacode

struct TelegramBotResponseFormatterTests {
  @Test func readResponseIsTruncatedWithRetryHint() throws {
    let payload = ReadCommandPayload(
      target: ReadTarget(
        worktree: ReadTargetWorktree(
          id: "wt-1",
          name: "main",
          path: "/Projects/Prowl",
          rootPath: "/Projects/Prowl",
          kind: "git"
        ),
        tab: ReadTargetTab(id: "tab-1", title: "zsh", selected: true),
        pane: ReadTargetPane(id: "pane-1", title: "zsh", cwd: "/Projects/Prowl", focused: true)
      ),
      mode: .last,
      last: 20,
      source: .screen,
      truncated: false,
      lineCount: 1,
      text: String(repeating: "x", count: 500)
    )
    let response = try CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1",
      data: RawJSON(encoding: payload)
    )

    let text = TelegramBotResponseFormatter(maxMessageLength: 160).format(response)

    #expect(text.count <= 160)
    #expect(text.contains("Try /read pane-1"))
  }
}
