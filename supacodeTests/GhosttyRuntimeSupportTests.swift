import AppKit
import Testing

@testable import supacode

@MainActor
struct GhosttyRuntimeSupportTests {
  @Test func escapePrefixesEveryShellMetacharacterOnce() {
    #expect(NSPasteboard.ghosttyEscape("/tmp/plain") == "/tmp/plain")
    #expect(NSPasteboard.ghosttyEscape("/tmp/My File (1).txt") == #"/tmp/My\ File\ \(1\).txt"#)
    #expect(NSPasteboard.ghosttyEscape(#"a\b"#) == #"a\\b"#)
    #expect(NSPasteboard.ghosttyEscape("it's $HOME") == #"it\'s\ \$HOME"#)
    #expect(NSPasteboard.ghosttyEscape("tab\there") == "tab\\\there")
  }

  @Test func hexColorAcceptsSixDigitsWithOptionalHash() throws {
    let color = try #require(NSColor(ghosttyHexColor: " #FF8000\n")?.usingColorSpace(.sRGB))
    #expect(color.redComponent == 1)
    #expect(abs(color.greenComponent - 128.0 / 255) < 0.0001)
    #expect(color.blueComponent == 0)

    #expect(NSColor(ghosttyHexColor: "00ff00") != nil)
    #expect(NSColor(ghosttyHexColor: "#fff") == nil)
    #expect(NSColor(ghosttyHexColor: "#GG0000") == nil)
  }
}
