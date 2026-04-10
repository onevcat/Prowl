import AppKit
import Foundation
import Testing

@testable import supacode

@MainActor
struct CommandPaletteRowColorTests {
  @Test func selectedForegroundUsesSelectionSemanticColorsInLightAppearance() throws {
    let colors = commandPaletteRowForegroundColors(isSelected: true)
    let appearance = try #require(NSAppearance(named: .aqua))

    try expectEqualColor(colors.primary, .alternateSelectedControlTextColor, appearance: appearance)
    try expectEqualColor(colors.secondary, .alternateSelectedControlTextColor, appearance: appearance)
  }

  @Test func selectedForegroundUsesSelectionSemanticColorsInDarkAppearance() throws {
    let colors = commandPaletteRowForegroundColors(isSelected: true)
    let appearance = try #require(NSAppearance(named: .darkAqua))

    try expectEqualColor(colors.primary, .alternateSelectedControlTextColor, appearance: appearance)
    try expectEqualColor(colors.secondary, .alternateSelectedControlTextColor, appearance: appearance)
  }

  @Test func unselectedForegroundUsesStandardLabelColors() throws {
    let colors = commandPaletteRowForegroundColors(isSelected: false)
    let appearance = try #require(NSAppearance(named: .aqua))

    try expectEqualColor(colors.primary, .labelColor, appearance: appearance)
    try expectEqualColor(colors.secondary, .secondaryLabelColor, appearance: appearance)
  }

  private func expectEqualColor(
    _ actual: NSColor,
    _ expected: NSColor,
    appearance: NSAppearance,
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column
  ) throws {
    let actualComponents = try #require(
      resolvedRGBA(for: actual, appearance: appearance),
      sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    )
    let expectedComponents = try #require(
      resolvedRGBA(for: expected, appearance: appearance),
      sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    )

    #expect(
      abs(actualComponents.red - expectedComponents.red) < 0.001,
      sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    )
    #expect(
      abs(actualComponents.green - expectedComponents.green) < 0.001,
      sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    )
    #expect(
      abs(actualComponents.blue - expectedComponents.blue) < 0.001,
      sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    )
    #expect(
      abs(actualComponents.alpha - expectedComponents.alpha) < 0.001,
      sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
    )
  }

  private func resolvedRGBA(
    for color: NSColor,
    appearance: NSAppearance
  ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
    var resolvedColor: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolvedColor = color.usingColorSpace(.sRGB)
    }
    guard let resolvedColor else { return nil }

    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (red, green, blue, alpha)
  }
}
