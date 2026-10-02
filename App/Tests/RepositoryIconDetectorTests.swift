import AppKit
import Dependencies
import Foundation
import Testing

@testable import supacode

struct RepositoryIconDetectorTests {
  // MARK: - Fixtures

  private func pngData(width: Int, height: Int) -> Data {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
    guard let bitmap, let data = bitmap.representation(using: .png, properties: [:]) else {
      Issue.record("Could not create PNG fixture")
      return Data()
    }
    return data
  }

  private var svgData: Data {
    let svg =
      #"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">"#
      + #"<rect width="64" height="64" fill="tomato"/></svg>"#
    return Data(svg.utf8)
  }

  /// Mimics Astro's default favicon: `fill="none"` on the root with
  /// paths colored only through an embedded `<style>` block, which
  /// CoreSVG ignores — NSImage renders it fully transparent.
  private var styleColoredSVGData: Data {
    let svg =
      #"<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 64 64">"#
      + #"<path d="M8 8h48v48H8z"/><style>path { fill: #000; }</style></svg>"#
    return Data(svg.utf8)
  }

  private struct ManifestEntry {
    var filename: String
    var size: String
    var scale: String?
  }

  private func appIconSetManifest(_ entries: [ManifestEntry]) -> Data {
    let images = entries.map { entry in
      var image = ["filename": entry.filename, "size": entry.size, "idiom": "mac"]
      if let scale = entry.scale {
        image["scale"] = scale
      }
      return image
    }
    guard let data = try? JSONSerialization.data(withJSONObject: ["images": images]) else {
      Issue.record("Could not encode manifest fixture")
      return Data()
    }
    return data
  }

  private let flutterPubspec = Data("name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n".utf8)
  private let reactNativePackageJSON = Data(
    #"{"name":"demo","dependencies":{"react":"19.0.0","react-native":"0.80.0"}}"#.utf8
  )

  // MARK: - Apple

  @Test func appleCatalogPicksLargestReferencedRaster() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["App.xcodeproj/"],
      contents: [
        "App/Assets.xcassets/AppIcon.appiconset/Contents.json": appIconSetManifest([
          .init(filename: "small.png", size: "16x16", scale: "1x"),
          .init(filename: "large.png", size: "512x512", scale: "2x"),
        ]),
        "App/Assets.xcassets/AppIcon.appiconset/small.png": pngData(width: 16, height: 16),
        "App/Assets.xcassets/AppIcon.appiconset/large.png": pngData(width: 1024, height: 1024),
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root)
      #expect(candidate?.evidence == .appleAssetCatalog)
      #expect(candidate?.imageURL.lastPathComponent == "large.png")
    }
  }

  @Test func appleCatalogFallsBackWhenLargestEntryFileIsMissing() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["Package.swift"],
      contents: [
        "Sources/App/Assets.xcassets/AppIcon.appiconset/Contents.json": appIconSetManifest([
          .init(filename: "missing.png", size: "512x512", scale: "2x"),
          .init(filename: "present.png", size: "128x128", scale: "1x"),
        ]),
        "Sources/App/Assets.xcassets/AppIcon.appiconset/present.png": pngData(width: 128, height: 128),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root)?.imageURL.lastPathComponent == "present.png")
    }
  }

  @Test func appleCatalogWithMalformedManifestYieldsNothing() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["App.xcodeproj/"],
      contents: [
        "Assets.xcassets/AppIcon.appiconset/Contents.json": Data("not json".utf8),
        "Assets.xcassets/AppIcon.appiconset/icon.png": pngData(width: 64, height: 64),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  @Test func appleCatalogInsideDependencyDirectoryIsIgnored() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["App.xcodeproj/"],
      contents: [
        "node_modules/pkg/Assets.xcassets/AppIcon.appiconset/Contents.json": appIconSetManifest([
          .init(filename: "icon.png", size: "64x64", scale: "1x")
        ]),
        "node_modules/pkg/Assets.xcassets/AppIcon.appiconset/icon.png": pngData(width: 64, height: 64),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  @Test func nearerAppleCatalogWinsOverDeeperOne() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["App.xcworkspace/"],
      contents: [
        "Assets.xcassets/AppIcon.appiconset/Contents.json": appIconSetManifest([
          .init(filename: "near.png", size: "64x64", scale: "1x")
        ]),
        "Assets.xcassets/AppIcon.appiconset/near.png": pngData(width: 64, height: 64),
        "Modules/Deep/Assets.xcassets/AppIcon.appiconset/Contents.json": appIconSetManifest([
          .init(filename: "deep.png", size: "1024x1024", scale: "1x")
        ]),
        "Modules/Deep/Assets.xcassets/AppIcon.appiconset/deep.png": pngData(width: 1024, height: 1024),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root)?.imageURL.lastPathComponent == "near.png")
    }
  }

  // MARK: - Android

  @Test func androidLauncherPrefersHighestDensity() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["gradlew", "settings.gradle"],
      contents: [
        "app/src/main/res/mipmap-mdpi/ic_launcher.png": pngData(width: 48, height: 48),
        "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png": pngData(width: 192, height: 192),
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root)
      #expect(candidate?.evidence == .androidLauncher)
      #expect(candidate?.imageURL.path(percentEncoded: false).contains("mipmap-xxxhdpi") == true)
    }
  }

  @Test func androidAdaptiveOnlyProjectYieldsNothing() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["gradlew"],
      contents: [
        "app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml": Data("<adaptive-icon/>".utf8)
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  // MARK: - Flutter / React Native

  @Test func flutterPrefersIOSRunnerCatalogOverAndroidLauncher() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "pubspec.yaml": flutterPubspec,
        "ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json": appIconSetManifest([
          .init(filename: "Icon-App-1024x1024@1x.png", size: "1024x1024", scale: "1x")
        ]),
        "ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png":
          pngData(width: 1024, height: 1024),
        "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png": pngData(width: 192, height: 192),
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root)
      #expect(candidate?.evidence == .appleAssetCatalog)
      #expect(candidate?.imageURL.path(percentEncoded: false).contains("ios/Runner") == true)
    }
  }

  @Test func flutterFallsBackToAndroidLauncher() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "pubspec.yaml": flutterPubspec,
        "android/app/src/main/res/mipmap-xhdpi/ic_launcher.png": pngData(width: 96, height: 96),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root)?.evidence == .androidLauncher)
    }
  }

  @Test func pureDartPackageWithoutFlutterYieldsNothing() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "pubspec.yaml": Data("name: pure_dart\nenvironment:\n  sdk: ^3.0.0\n".utf8),
        "android/app/src/main/res/mipmap-xhdpi/ic_launcher.png": pngData(width: 96, height: 96),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  @Test func reactNativeUsesIOSCatalogThenAndroid() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": reactNativePackageJSON,
        "ios/Demo/Images.xcassets/AppIcon.appiconset/Contents.json": appIconSetManifest([
          .init(filename: "AppIcon.png", size: "1024x1024")
        ]),
        "ios/Demo/Images.xcassets/AppIcon.appiconset/AppIcon.png": pngData(width: 1024, height: 1024),
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root)
      #expect(candidate?.evidence == .appleAssetCatalog)
    }
  }

  // MARK: - Web

  @Test func webManifestIconWinsOverFavicon() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"site"}"#.utf8),
        "public/manifest.json": Data(
          #"{"icons":[{"src":"icons/icon-192.png","sizes":"192x192"},{"src":"icons/icon-512.png","sizes":"512x512"}]}"#
            .utf8
        ),
        "public/icons/icon-192.png": pngData(width: 192, height: 192),
        "public/icons/icon-512.png": pngData(width: 512, height: 512),
        "public/favicon.png": pngData(width: 32, height: 32),
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root)
      #expect(candidate?.evidence == .webAsset)
      #expect(candidate?.imageURL.lastPathComponent == "icon-512.png")
    }
  }

  @Test func htmlRelIconIsResolvedAgainstRoot() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"site"}"#.utf8),
        "index.html": Data(
          #"<html><head><link rel="icon" href="/assets/fav.png"></head></html>"#.utf8
        ),
        "assets/fav.png": pngData(width: 64, height: 64),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root)?.imageURL.lastPathComponent == "fav.png")
    }
  }

  @Test func staticFolderWithIndexHTMLAndFaviconQualifies() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "index.html": Data("<html></html>".utf8),
        "favicon.svg": svgData,
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root)
      #expect(candidate?.evidence == .webAsset)
      #expect(candidate?.imageURL.lastPathComponent == "favicon.svg")
    }
  }

  @Test func rootLogoIsLastResortForWebProjects() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"site"}"#.utf8),
        "logo.svg": svgData,
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root)?.imageURL.lastPathComponent == "logo.svg")
    }
  }

  @Test func nonWebProjectRootLogoFallsToGenericTier() async throws {
    // Originally rejected outright; the generic fallback tier now
    // accepts a near-square root logo for any project kind.
    try await withTemporaryProjectDirectory(
      entries: ["go.mod"],
      contents: [
        "logo.svg": svgData
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root)?.evidence == .genericAsset)
    }
  }

  @Test func remoteAndDataIconReferencesAreRejected() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"site"}"#.utf8),
        "index.html": Data(
          #"<html><head><link rel="icon" href="https://cdn.example.com/fav.png"></head></html>"#.utf8
        ),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  // MARK: - Validation

  @Test func undecodableImageIsRejected() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"site"}"#.utf8),
        "logo.png": Data("this is not a png".utf8),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  @Test func oversizedRasterIsRejected() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"site"}"#.utf8),
        "logo.png": pngData(width: 5000, height: 16),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  @Test func symlinkEscapingTheRepositoryIsRejected() async throws {
    let fileManager = FileManager.default
    let outside = fileManager.temporaryDirectory
      .appending(path: "outside-\(UUID().uuidString).png")
    try pngData(width: 64, height: 64).write(to: outside)
    defer { try? fileManager.removeItem(at: outside) }
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"site"}"#.utf8)
      ]
    ) { root in
      try fileManager.createSymbolicLink(
        at: root.appending(path: "logo.png"),
        withDestinationURL: outside
      )
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  @Test func emptyRepositoryYieldsNothing() async throws {
    try await withTemporaryProjectDirectory(entries: ["README.md"]) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  // MARK: - Icon Composer

  @Test func iconComposerBundleWinsOverAssetCatalog() async throws {
    let rendered = FileManager.default.temporaryDirectory
      .appending(path: "rendered-\(UUID().uuidString).png")
    try pngData(width: 512, height: 512).write(to: rendered)
    defer { try? FileManager.default.removeItem(at: rendered) }
    try await withTemporaryProjectDirectory(
      entries: ["App.xcodeproj/"],
      contents: [
        "assets/AppIcon.icon/icon.json": Data(#"{"fill":{"solid":"srgb:1,1,1,1"},"groups":[]}"#.utf8),
        "assets/AppIcon.icon/Assets/layer.svg": svgData,
        "Assets.xcassets/AppIcon.appiconset/Contents.json": appIconSetManifest([
          .init(filename: "legacy.png", size: "512x512", scale: "1x")
        ]),
        "Assets.xcassets/AppIcon.appiconset/legacy.png": pngData(width: 512, height: 512),
      ]
    ) { root in
      let requested = LockIsolated<[URL]>([])
      let candidate = await RepositoryIconDetector.detect(at: root) { bundle in
        requested.withValue { $0.append(bundle) }
        return rendered
      }
      #expect(candidate?.evidence == .appleIconComposer)
      #expect(candidate?.imageURL == rendered)
      #expect(candidate?.ownsImageFile == true)
      #expect(requested.value.first?.lastPathComponent == "AppIcon.icon")
    }
  }

  @Test func unrenderableIconComposerBundleFallsBackToAssetCatalog() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["App.xcodeproj/"],
      contents: [
        "AppIcon.icon/icon.json": Data(#"{"groups":[]}"#.utf8),
        "Assets.xcassets/AppIcon.appiconset/Contents.json": appIconSetManifest([
          .init(filename: "legacy.png", size: "512x512", scale: "1x")
        ]),
        "Assets.xcassets/AppIcon.appiconset/legacy.png": pngData(width: 512, height: 512),
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root) { _ in nil }
      #expect(candidate?.evidence == .appleAssetCatalog)
    }
  }

  @Test func iconDirectoryWithoutManifestIsNotRendered() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["Package.swift", "Some.icon/"]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root) { _ in
        Issue.record("Renderer must not run without a valid icon.json")
        return nil
      }
      #expect(candidate == nil)
    }
  }

  // MARK: - Tauri

  @Test func tauriBundleIconIsUsed() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"app"}"#.utf8),
        "src-tauri/tauri.conf.json": Data(
          #"{"bundle":{"icon":["icons/32x32.png","icons/icon.icns","icons/icon.png"]}}"#.utf8
        ),
        "src-tauri/icons/32x32.png": pngData(width: 32, height: 32),
        "src-tauri/icons/icon.png": pngData(width: 1024, height: 1024),
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root)
      #expect(candidate?.evidence == .tauriBundle)
      #expect(candidate?.imageURL.lastPathComponent == "icon.png")
    }
  }

  @Test func tauriV1ConfigShapeIsSupported() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "src-tauri/tauri.conf.json": Data(
          #"{"tauri":{"bundle":{"icon":["icons/icon.png"]}}}"#.utf8
        ),
        "src-tauri/icons/icon.png": pngData(width: 512, height: 512),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root)?.evidence == .tauriBundle)
    }
  }

  // MARK: - package.json icon field

  @Test func packageJSONIconFieldOutranksFavicon() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"ext","icon":"images/ext-icon.png"}"#.utf8),
        "images/ext-icon.png": pngData(width: 128, height: 128),
        "public/favicon.png": pngData(width: 32, height: 32),
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root)
      #expect(candidate?.evidence == .webAsset)
      #expect(candidate?.imageURL.lastPathComponent == "ext-icon.png")
    }
  }

  // MARK: - Generic fallback

  @Test func genericTierAcceptsNearSquareRootIconForAnyKind() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["go.mod"],
      contents: [
        "icon.png": pngData(width: 256, height: 256)
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root)
      #expect(candidate?.evidence == .genericAsset)
      #expect(candidate?.imageURL.lastPathComponent == "icon.png")
    }
  }

  @Test func genericTierFindsAssetsAndGithubLocations() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["Cargo.toml"],
      contents: [
        ".github/logo.png": pngData(width: 300, height: 260)
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root)?.evidence == .genericAsset)
    }
  }

  @Test func genericTierRejectsWideWordmarkLogo() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["go.mod"],
      contents: [
        "assets/logo.png": pngData(width: 1200, height: 300)
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  @Test func kindProbeStillWinsOverGenericTier() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["gradlew"],
      contents: [
        "app/src/main/res/mipmap-xhdpi/ic_launcher.png": pngData(width: 96, height: 96),
        "icon.png": pngData(width: 256, height: 256),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root)?.evidence == .androidLauncher)
    }
  }

  // MARK: - Hostile manifests

  @Test func hostileAppIconManifestNumbersDoNotTrap() async throws {
    // Infinity/NaN products must not reach `Int(_:)`, and the clamped
    // hostile entry must not block a valid fallback candidate.
    try await withTemporaryProjectDirectory(
      entries: ["App.xcodeproj/"],
      contents: [
        "Assets.xcassets/AppIcon.appiconset/Contents.json": appIconSetManifest([
          .init(filename: "evil.png", size: "1e308x1e308", scale: "1e308x"),
          .init(filename: "weird.png", size: "nanxnan", scale: "nanx"),
          .init(filename: "good.png", size: "128x128", scale: "1x"),
        ]),
        "Assets.xcassets/AppIcon.appiconset/evil.png": Data("not an image".utf8),
        "Assets.xcassets/AppIcon.appiconset/good.png": pngData(width: 128, height: 128),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root)?.imageURL.lastPathComponent == "good.png")
    }
  }

  @Test func hostileWebManifestSizesDoNotTrap() async throws {
    // Int.max × 2 would overflow checked multiplication; out-of-range
    // dimensions are ignored, the icon itself remains usable.
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"site"}"#.utf8),
        "manifest.json": Data(
          #"{"icons":[{"src":"icon.png","sizes":"9223372036854775807x2 -5x-5"}]}"#.utf8
        ),
        "icon.png": pngData(width: 256, height: 256),
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root)
      #expect(candidate?.evidence == .webAsset)
      #expect(candidate?.imageURL.lastPathComponent == "icon.png")
    }
  }

  @Test func invisiblyRenderingSVGFaviconFallsBackToRasterFavicon() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"site"}"#.utf8),
        "public/favicon.svg": styleColoredSVGData,
        "public/favicon.png": pngData(width: 32, height: 32),
      ]
    ) { root in
      let candidate = await RepositoryIconDetector.detect(at: root)
      #expect(candidate?.evidence == .webAsset)
      #expect(candidate?.imageURL.lastPathComponent == "favicon.png")
    }
  }

  @Test func invisiblyRenderingSVGAloneYieldsNothing() async throws {
    try await withTemporaryProjectDirectory(
      entries: [],
      contents: [
        "package.json": Data(#"{"name":"site"}"#.utf8),
        "public/favicon.svg": styleColoredSVGData,
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  @Test func oversizedSVGCanvasIsRejected() async throws {
    let hugeSVG =
      #"<svg xmlns="http://www.w3.org/2000/svg" width="99999" height="99999">"#
      + #"<rect width="99999" height="99999" fill="tomato"/></svg>"#
    try await withTemporaryProjectDirectory(
      entries: ["package.json"],
      contents: [
        "logo.svg": Data(hugeSVG.utf8)
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }

  @Test func genericTierIgnoresUnrelatedFilenames() async throws {
    try await withTemporaryProjectDirectory(
      entries: ["go.mod"],
      contents: [
        "banner.png": pngData(width: 256, height: 256),
        "assets/screenshot.png": pngData(width: 256, height: 256),
      ]
    ) { root in
      #expect(await RepositoryIconDetector.detect(at: root) == nil)
    }
  }
}
