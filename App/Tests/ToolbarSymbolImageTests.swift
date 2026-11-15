import AppKit
import Testing

@testable import Prowl

@MainActor
struct ToolbarSymbolImageTests {
  @Test func reusesTheImageForTheSameConfiguration() {
    let first = ToolbarSymbolImage.nsImage("play.fill")
    let second = ToolbarSymbolImage.nsImage("play.fill")

    #expect(first === second)
  }

  @Test func sizesTheSymbolForTheTextStyleAndScale() {
    let body = ToolbarSymbolImage.nsImage("play.fill", textStyle: .body, scale: .large)
    let small = ToolbarSymbolImage.nsImage("play.fill", textStyle: .caption2, scale: .small)

    #expect(body !== small)
    #expect(body.size.height > small.size.height)
  }

  @Test func keepsTheSymbolATemplate() {
    #expect(ToolbarSymbolImage.nsImage("bell.fill").isTemplate)
  }
}
