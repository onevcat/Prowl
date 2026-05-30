import AppKit
import Testing

@testable import supacode

struct GhosttySearchFieldCommandTests {
  @Test func returnCommandSubmitsNextResult() {
    let command = GhosttySearchFieldCommand.command(
      for: #selector(NSResponder.insertNewline(_:)),
      modifierFlags: []
    )

    #expect(command == .submit(isShifted: false))
  }

  @Test func shiftedReturnCommandSubmitsPreviousResult() {
    let command = GhosttySearchFieldCommand.command(
      for: #selector(NSResponder.insertNewline(_:)),
      modifierFlags: [.shift]
    )

    #expect(command == .submit(isShifted: true))
  }

  @Test func escapeCommandCancelsSearch() {
    let command = GhosttySearchFieldCommand.command(
      for: #selector(NSResponder.cancelOperation(_:)),
      modifierFlags: []
    )

    #expect(command == .escape)
  }
}
