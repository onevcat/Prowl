import AppKit
import ProwlCLIShared
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct PlainTextEditorTests {
  @Test func textUpdateAfterMiddleInsertionPreservesCaret() throws {
    let fixture = PlainTextEditorFixture(text: "abcdef")
    let textView = try #require(fixture.textView)
    textView.selectedRange = NSRange(location: 4, length: 0)

    fixture.text = "abcXdef"
    fixture.update()

    #expect(fixture.textView === textView)
    #expect(textView.string == "abcXdef")
    #expect(textView.selectedRange() == NSRange(location: 4, length: 0))
  }

  @Test func textUpdateAfterMiddleDeletionPreservesCaret() throws {
    let fixture = PlainTextEditorFixture(text: "abcdef")
    let textView = try #require(fixture.textView)
    textView.selectedRange = NSRange(location: 2, length: 0)

    fixture.text = "abdef"
    fixture.update()

    #expect(fixture.textView === textView)
    #expect(textView.string == "abdef")
    #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
  }

  @Test func staleRefreshDuringMiddleTypingKeepsTextAndCaret() throws {
    let fixture = PlainTextEditorFixture(text: "abcdef")
    let textView = try #require(fixture.textView)
    textView.setSelectedRange(NSRange(location: 3, length: 0))
    textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(fixture.text == "abcXdef")
    #expect(textView.selectedRange() == NSRange(location: 4, length: 0))

    fixture.text = "abcdef"
    fixture.update()

    #expect(textView.string == "abcXdef")
    #expect(textView.selectedRange() == NSRange(location: 4, length: 0))

    fixture.text = "abcXdef"
    fixture.update()

    #expect(textView.string == "abcXdef")
    #expect(textView.selectedRange() == NSRange(location: 4, length: 0))
  }

  @Test func staleRefreshDuringEndTypingKeepsTextAndCaret() throws {
    let fixture = PlainTextEditorFixture(text: "abcdef")
    let textView = try #require(fixture.textView)
    textView.setSelectedRange(NSRange(location: 6, length: 0))
    textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(fixture.text == "abcdefX")

    fixture.text = "abcdef"
    fixture.update()

    #expect(textView.string == "abcdefX")

    fixture.text = "abcdefX"
    fixture.update()

    #expect(textView.string == "abcdefX")
    #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
  }

  @Test func staleRefreshDuringMiddleDeletionKeepsTextAndCaret() throws {
    let fixture = PlainTextEditorFixture(text: "abcdef")
    let textView = try #require(fixture.textView)
    textView.setSelectedRange(NSRange(location: 3, length: 0))
    textView.deleteBackward(nil)
    #expect(fixture.text == "abdef")
    #expect(textView.selectedRange() == NSRange(location: 2, length: 0))

    fixture.text = "abcdef"
    fixture.update()

    #expect(textView.string == "abdef")

    fixture.text = "abdef"
    fixture.update()

    #expect(textView.string == "abdef")
    #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
  }

  @Test func externalChangeAfterEditRoundTripStillApplies() throws {
    let fixture = PlainTextEditorFixture(text: "abcdef")
    let textView = try #require(fixture.textView)
    textView.setSelectedRange(NSRange(location: 6, length: 0))
    textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    fixture.update()

    fixture.text = "xyz"
    fixture.update()

    #expect(textView.string == "xyz")
    #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
  }

  @Test func externalChangeClampsSelectionToNewLength() throws {
    let fixture = PlainTextEditorFixture(text: "abcdef")
    let textView = try #require(fixture.textView)
    textView.setSelectedRange(NSRange(location: 4, length: 2))

    fixture.text = "abc"
    fixture.update()

    #expect(textView.string == "abc")
    #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
  }
}

@MainActor
private final class PlainTextEditorFixture {
  var text: String {
    get { storage.text }
    set { storage.text = newValue }
  }

  private let storage: PlainTextEditorTextStorage
  private var revision = 0
  private let textBinding: Binding<String>
  private let window: NSWindow
  private let hostingView: NSHostingView<EditorHost>

  init(text: String) {
    let storage = PlainTextEditorTextStorage(text: text)
    self.storage = storage
    textBinding = Binding(
      get: { storage.text },
      set: { storage.text = $0 }
    )
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    hostingView = NSHostingView(rootView: EditorHost(text: textBinding, revision: 0))
    window.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()
  }

  var textView: PlainTextEditor.PlaceholderTextView? {
    findTextView(in: hostingView)
  }

  func update() {
    revision += 1
    hostingView.rootView = EditorHost(text: textBinding, revision: revision)
    hostingView.layoutSubtreeIfNeeded()
  }

  private func findTextView(in view: NSView) -> PlainTextEditor.PlaceholderTextView? {
    if let textView = view as? PlainTextEditor.PlaceholderTextView {
      return textView
    }

    for subview in view.subviews {
      if let textView = findTextView(in: subview) {
        return textView
      }
    }

    return nil
  }
}

@MainActor
private final class PlainTextEditorTextStorage {
  var text: String

  init(text: String) {
    self.text = text
  }
}

private struct EditorHost: View {
  let text: Binding<String>
  let revision: Int

  var body: some View {
    PlainTextEditor(
      text: text,
      isMonospaced: true,
      placeholder: "Command \(revision)"
    )
  }
}
