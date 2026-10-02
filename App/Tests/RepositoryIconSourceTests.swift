import Foundation
import Testing

@testable import supacode

struct RepositoryIconSourceTests {
  // MARK: - storageString encoding

  @Test func sfSymbolSerialisesBare() {
    let icon = RepositoryIconSource.sfSymbol("folder.fill")
    #expect(icon.storageString == "folder.fill")
  }

  @Test func bundledAssetUsesAssetMarker() {
    let icon = RepositoryIconSource.bundledAsset("Docker")
    #expect(icon.storageString == "@asset:Docker")
  }

  @Test func userImageUsesFileMarker() {
    let icon = RepositoryIconSource.userImage(filename: "abc.png")
    #expect(icon.storageString == "@file:abc.png")
  }

  // MARK: - parse

  @Test func parseEmptyReturnsNil() {
    #expect(RepositoryIconSource.parse("") == nil)
    #expect(RepositoryIconSource.parse("   ") == nil)
  }

  @Test func parseBareStringIsSFSymbol() {
    #expect(RepositoryIconSource.parse("folder") == .sfSymbol("folder"))
  }

  @Test func parseAssetMarker() {
    #expect(RepositoryIconSource.parse("@asset:Docker") == .bundledAsset("Docker"))
  }

  @Test func parseFileMarker() {
    #expect(RepositoryIconSource.parse("@file:abc.svg") == .userImage(filename: "abc.svg"))
  }

  @Test func parseTrimsWhitespace() {
    #expect(RepositoryIconSource.parse("  folder.fill  ") == .sfSymbol("folder.fill"))
  }

  @Test func parsePreservesFilenameWithDots() {
    // Filenames carry the extension; the parser must not strip dots.
    let icon = RepositoryIconSource.parse("@file:logo.repo.svg")
    #expect(icon == .userImage(filename: "logo.repo.svg"))
  }

  // MARK: - Round-trip

  @Test func sfSymbolRoundTrip() {
    let source = RepositoryIconSource.sfSymbol("hammer")
    #expect(RepositoryIconSource.parse(source.storageString) == source)
  }

  @Test func bundledAssetRoundTrip() {
    let source = RepositoryIconSource.bundledAsset("Visual Studio Code")
    #expect(RepositoryIconSource.parse(source.storageString) == source)
  }

  @Test func userImageRoundTrip() {
    let source = RepositoryIconSource.userImage(filename: "abc-123.png")
    #expect(RepositoryIconSource.parse(source.storageString) == source)
  }

  // MARK: - Codable (single-value String)

  @Test func encodesAsSingleString() throws {
    let icon = RepositoryIconSource.sfSymbol("folder.fill")
    let data = try JSONEncoder().encode(icon)
    let decoded = try JSONDecoder().decode(String.self, from: data)
    #expect(decoded == "folder.fill")
  }

  @Test func decodesFromSingleString() throws {
    let raw = Data("\"@file:abc.png\"".utf8)
    let decoded = try JSONDecoder().decode(RepositoryIconSource.self, from: raw)
    #expect(decoded == .userImage(filename: "abc.png"))
  }

  @Test func decodingEmptyStringFails() {
    let raw = Data("\"\"".utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(RepositoryIconSource.self, from: raw)
    }
  }

  // MARK: - isTintable

  @Test func sfSymbolIsTintable() {
    #expect(RepositoryIconSource.sfSymbol("folder").isTintable)
  }

  @Test func bundledAssetIsNotTintable() {
    #expect(!RepositoryIconSource.bundledAsset("Docker").isTintable)
  }

  @Test func pngUserImageIsNotTintable() {
    #expect(!RepositoryIconSource.userImage(filename: "abc.png").isTintable)
  }

  @Test func pngUserImageWithUppercaseExtensionIsNotTintable() {
    #expect(!RepositoryIconSource.userImage(filename: "abc.PNG").isTintable)
  }

  @Test func svgUserImageIsTintable() {
    #expect(RepositoryIconSource.userImage(filename: "abc.svg").isTintable)
  }

  @Test func svgUserImageWithUppercaseExtensionIsTintable() {
    #expect(RepositoryIconSource.userImage(filename: "abc.SVG").isTintable)
  }

  // MARK: - detectedImage

  @Test func detectedImageUsesDetectedMarker() {
    let icon = RepositoryIconSource.detectedImage(filename: "abc.png")
    #expect(icon.storageString == "@detected:abc.png")
  }

  @Test func parseDetectedMarker() {
    #expect(
      RepositoryIconSource.parse("@detected:abc.svg") == .detectedImage(filename: "abc.svg")
    )
  }

  @Test func detectedImageRoundTrip() {
    let source = RepositoryIconSource.detectedImage(filename: "abc-123.webp")
    #expect(RepositoryIconSource.parse(source.storageString) == source)
  }

  @Test func detectedImageIsNeverTintable() {
    // A detected SVG keeps its intrinsic colors — unlike a user SVG.
    #expect(!RepositoryIconSource.detectedImage(filename: "abc.svg").isTintable)
    #expect(!RepositoryIconSource.detectedImage(filename: "abc.png").isTintable)
  }

  // MARK: - storedImageFilename

  @Test func storedImageFilenameCoversFileBackedCases() {
    #expect(RepositoryIconSource.userImage(filename: "a.png").storedImageFilename == "a.png")
    #expect(RepositoryIconSource.detectedImage(filename: "b.svg").storedImageFilename == "b.svg")
    #expect(RepositoryIconSource.sfSymbol("folder").storedImageFilename == nil)
    #expect(RepositoryIconSource.bundledAsset("Docker").storedImageFilename == nil)
  }
}
