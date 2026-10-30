import AppKit
import GhosttyKit
import Testing

@testable import Prowl

/// Clipboard requests that libghostty holds for the user: unsafe pastes and
/// program clipboard access under an `ask` policy.
@MainActor
struct GhosttyClipboardConfirmationTests {
  private func makeSurfaceView() -> GhosttySurfaceView {
    GhosttySurfaceView(
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
  }

  private func makeConfirmation(
    canRemember: Bool = false,
    onResolve: @escaping (Bool, Bool) -> Void = { _, _ in }
  ) -> GhosttyClipboardConfirmation {
    GhosttyClipboardConfirmation(
      kind: .paste,
      preview: GhosttyClipboardPreview(text: "ls\n"),
      canRemember: canRemember,
      completion: onResolve
    )
  }

  @Test func requestKindsMapFromLibghostty() {
    #expect(GhosttyClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_PASTE) == .paste)
    #expect(GhosttyClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ) == .osc52Read)
    #expect(GhosttyClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE) == .osc52Write)
    #expect(GhosttyClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ) == .kittyRead)
    #expect(GhosttyClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE) == .kittyWrite)
    // A listing never needs confirmation, so it is not a kind the user sees.
    #expect(GhosttyClipboardRequestKind(GHOSTTY_CLIPBOARD_REQUEST_LIST) == nil)
  }

  @Test func pasteAndProgramRequestsUseTheirOwnButtons() {
    #expect(GhosttyClipboardRequestKind.paste.confirmButtonTitle == "Paste")
    #expect(GhosttyClipboardRequestKind.paste.cancelButtonTitle == "Cancel")
    #expect(GhosttyClipboardRequestKind.osc52Read.confirmButtonTitle == "Allow")
    #expect(GhosttyClipboardRequestKind.kittyWrite.cancelButtonTitle == "Deny")
  }

  @Test func previewShowsPlainTextWithVisibleControlCharacters() {
    let text = "echo a\r\necho b\trm -rf x\r\u{1B}[201~"
    let preview = GhosttyClipboardPreview(contents: [
      GhosttyClipboardContent(mime: "text/html", data: Data("<b>x</b>".utf8)),
      GhosttyClipboardContent(mime: "text/plain", data: Data(text.utf8)),
    ])
    #expect(preview.text == "echo a\necho b\trm -rf x\\u{D}\\u{1B}[201~")
    #expect(preview.imageData == nil)
  }

  @Test func previewSummarizesRepresentationsWithoutText() {
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let preview = GhosttyClipboardPreview(contents: [
      GhosttyClipboardContent(mime: "image/png", data: png)
    ])
    #expect(preview.text == "image/png (4 bytes)")
    #expect(preview.imageData == png)
  }

  @Test func previewCutsLongText() {
    let limit = GhosttyClipboardPreview.maxDisplayedCharacters
    let text = GhosttyClipboardPreview.displayText(String(repeating: "a", count: limit + 5))
    #expect(text == String(repeating: "a", count: limit) + "\n… 5 more characters not shown")
  }

  @Test func confirmationResolvesOnce() {
    var results: [(Bool, Bool)] = []
    let confirmation = makeConfirmation { results.append(($0, $1)) }
    confirmation.allow()
    confirmation.deny()
    confirmation.allow()
    #expect(confirmation.isResolved)
    #expect(results.count == 1)
    #expect(results.first?.0 == true)
  }

  @Test func rememberNeedsAGrantableRequest() {
    var remembered: [Bool] = []
    makeConfirmation(canRemember: false) { remembered.append($1) }.allow(remember: true)
    makeConfirmation(canRemember: true) { remembered.append($1) }.allow(remember: true)
    #expect(remembered == [false, true])
  }

  @Test func backgroundRequestWaitsAndRingsTheBell() {
    let view = makeSurfaceView()
    let confirmation = makeConfirmation()

    view.requestClipboardConfirmation(confirmation)

    #expect(view.pendingClipboardConfirmation === confirmation)
    #expect(view.clipboardConfirmationAlert == nil)
    #expect(view.bridge.state.bellCount == 1)
    #expect(!confirmation.isResolved)
  }

  @Test func newerRequestDeniesTheOlderOne() {
    let view = makeSurfaceView()
    var firstResult: Bool?
    let first = makeConfirmation { allowed, _ in firstResult = allowed }
    let second = makeConfirmation()

    view.requestClipboardConfirmation(first)
    view.requestClipboardConfirmation(second)

    #expect(firstResult == false)
    #expect(view.pendingClipboardConfirmation === second)
    #expect(!second.isResolved)
  }

  @Test func closingTheSurfaceDeniesThePendingRequest() {
    let view = makeSurfaceView()
    var result: Bool?
    view.requestClipboardConfirmation(makeConfirmation { allowed, _ in result = allowed })

    view.closeSurface()

    #expect(result == false)
    #expect(view.pendingClipboardConfirmation == nil)
  }

  @Test func suspendingForUndoDeniesThePendingRequest() {
    let view = makeSurfaceView()
    var result: Bool?
    view.requestClipboardConfirmation(makeConfirmation { allowed, _ in result = allowed })

    view.suspendForPendingClose()

    #expect(result == false)
    #expect(view.pendingClipboardConfirmation == nil)
  }
}
