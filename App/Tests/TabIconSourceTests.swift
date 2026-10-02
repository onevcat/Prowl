import Testing

@testable import supacode

struct TabIconSourceTests {
  // MARK: - storageString encoding

  @Test func sfSymbolOnlySerialisesBare() {
    // SF-Symbol-only entries serialise as the bare symbol name so
    // the existing IconPicker storage path keeps working unchanged.
    let icon = TabIconSource(systemSymbol: "terminal")
    #expect(icon.storageString == "terminal")
  }

  @Test func assetEntrySerialisesWithMarker() {
    // Asset-bearing entries get the `@asset:` prefix the renderer
    // parses via `ResolvedTabIcon`.
    let icon = TabIconSource(systemSymbol: "shippingbox", assetName: "Docker")
    #expect(icon.storageString == "@asset:Docker")
  }

  @Test func assetEntryOmitsSystemSymbolFromStorage() {
    // `systemSymbol` stays only as a fallback for renderers that
    // can't resolve the asset; storage carries the asset.
    let icon = TabIconSource(systemSymbol: "sparkle", assetName: "ClaudeCode")
    #expect(icon.storageString == "@asset:ClaudeCode")
    #expect(!icon.storageString.contains("sparkle"))
  }

  // MARK: - ResolvedTabIcon parsing

  @Test func parsesBareStringAsSystemSymbol() {
    let resolved = ResolvedTabIcon.parse("terminal")
    #expect(resolved == .systemSymbol("terminal"))
  }

  @Test func parsesAssetMarker() {
    let resolved = ResolvedTabIcon.parse("@asset:Docker")
    #expect(resolved == .asset(name: "Docker"))
  }

  @Test func parsesAssetMarkerWithSpaces() {
    // Asset names can contain spaces (e.g. "Visual Studio Code"), so
    // the parser must keep everything after the marker prefix intact.
    let resolved = ResolvedTabIcon.parse("@asset:Visual Studio Code")
    #expect(resolved == .asset(name: "Visual Studio Code"))
  }

  @Test func sfSymbolStringWithColonStaysSymbol() {
    // Edge: SF Symbol names never start with `@asset:`, so a literal
    // colon-bearing symbol (none today, but defensive) doesn't trip
    // the parser.
    let resolved = ResolvedTabIcon.parse("foo:bar")
    #expect(resolved == .systemSymbol("foo:bar"))
  }

  // MARK: - Round-trip

  @Test func sfSymbolRoundTrip() {
    let source = TabIconSource(systemSymbol: "hammer")
    let parsed = ResolvedTabIcon.parse(source.storageString)
    #expect(parsed == .systemSymbol("hammer"))
  }

  @Test func assetRoundTrip() {
    let source = TabIconSource(systemSymbol: "shippingbox", assetName: "Npm")
    let parsed = ResolvedTabIcon.parse(source.storageString)
    #expect(parsed == .asset(name: "Npm"))
  }
}
