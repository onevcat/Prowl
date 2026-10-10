import GhosttyKit
import Testing

@testable import Prowl

/// `GhosttyProgramStatusReport` copies an OSC 7501 action out of libghostty
/// (`GHOSTTY_ACTION_PROGRAM_STATUS`) before its strings go away.
struct GhosttyProgramStatusReportTests {
  private func makeReport(
    state: ghostty_action_program_status_state_e,
    kind: ghostty_action_program_status_kind_e = GHOSTTY_PROGRAM_STATUS_KIND_NONE,
    progress: Int8 = -1,
    id: String = "",
    app: String = "",
    title: String = "",
    message: String = ""
  ) -> GhosttyProgramStatusReport? {
    id.withCString { id in
      app.withCString { app in
        title.withCString { title in
          message.withCString { message in
            GhosttyProgramStatusReport(
              ghostty_action_program_status_s(
                state: state, kind: kind, progress: progress,
                id: id, app: app, title: title, message: message
              )
            )
          }
        }
      }
    }
  }

  @Test func blockedReportKeepsKindProgressAndText() {
    let report = makeReport(
      state: GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED,
      kind: GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION,
      progress: 40,
      id: "build/test",
      app: "claude-code",
      title: "Tests",
      message: "approve Bash: ls -la"
    )

    #expect(
      report
        == GhosttyProgramStatusReport(
          state: .blocked, kind: .permission, progress: 40, id: "build/test",
          app: "claude-code", title: "Tests", message: "approve Bash: ls -la"
        )
    )
  }

  @Test func absentFieldsBecomeNilAndTheRootIdStaysEmpty() {
    let report = makeReport(state: GHOSTTY_PROGRAM_STATUS_STATE_IDLE)

    #expect(report == GhosttyProgramStatusReport(state: .idle))
    #expect(report?.id == "")
    #expect(report?.kind == nil)
    #expect(report?.progress == nil)
  }

  @Test func clearWithoutIdAddressesEveryRecord() {
    let report = makeReport(state: GHOSTTY_PROGRAM_STATUS_STATE_CLEAR)

    #expect(report?.state == .clear)
    #expect(report?.id == "")
  }

  @Test func unknownStateIsRejected() {
    let report = makeReport(state: ghostty_action_program_status_state_e(rawValue: 99))

    #expect(report == nil)
  }

  @Test func textIsCopiedOutOfTheCallback() {
    var copied: GhosttyProgramStatusReport?
    do {
      let transient = String(repeating: "x", count: 64) + "-done"
      copied = makeReport(state: GHOSTTY_PROGRAM_STATUS_STATE_DONE, message: transient)
    }

    #expect(copied?.message?.hasSuffix("-done") == true)
    #expect(copied?.message?.count == 69)
  }
}
