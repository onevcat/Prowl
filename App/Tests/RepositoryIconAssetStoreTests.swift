import Foundation
import Testing

@testable import supacode

/// RAII helper: creates a unique scratch directory under `$TMPDIR` and
/// removes it on deinit so test runs don't accumulate orphan folders
/// between invocations (we ship to `make test` repeatedly during dev).
private final class ScratchDirectory {
  let url: URL

  init(prefix: String) {
    url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

@MainActor
struct RepositoryIconAssetStoreTests {
  // MARK: - Helpers

  private struct StoreFixture {
    let store: RepositoryIconAssetStore
    let repoRoot: ScratchDirectory
    let iconStoreRoot: ScratchDirectory

    func iconsDirectory() -> URL {
      iconStoreRoot.url
        .appending(path: repoRoot.url.lastPathComponent, directoryHint: .isDirectory)
        .appending(path: "icons", directoryHint: .isDirectory)
    }
  }

  private func makeRepoRootScratch() -> ScratchDirectory {
    ScratchDirectory(prefix: "prowl-icon-store")
  }

  private func makeStoreFixture() -> StoreFixture {
    let repoRoot = makeRepoRootScratch()
    let iconStoreRoot = ScratchDirectory(prefix: "prowl-icon-store-home")
    let store = RepositoryIconAssetStore.fileSystemValue { rootURL in
      iconStoreRoot.url
        .appending(path: rootURL.lastPathComponent, directoryHint: .isDirectory)
        .appending(path: "icons", directoryHint: .isDirectory)
    }
    return StoreFixture(store: store, repoRoot: repoRoot, iconStoreRoot: iconStoreRoot)
  }

  private func writeSourceFile(
    in scratch: ScratchDirectory,
    extension ext: String,
    contents: Data = Data([0xDE, 0xAD])
  ) throws -> URL {
    let url = scratch.url.appending(path: "icon.\(ext)", directoryHint: .notDirectory)
    try contents.write(to: url)
    return url
  }

  // MARK: - importImage

  @Test func importImageCopiesFileWithUUIDName() throws {
    let fixture = makeStoreFixture()
    let source = ScratchDirectory(prefix: "prowl-icon-source")
    let sourceFile = try writeSourceFile(
      in: source, extension: "png", contents: Data([0x01, 0x02, 0x03])
    )

    let filename = try fixture.store.importImage(sourceFile, fixture.repoRoot.url)

    #expect(filename.hasSuffix(".png"))
    #expect(UUID(uuidString: String(filename.dropLast(4))) != nil)

    let resolved = fixture.iconsDirectory().appending(path: filename, directoryHint: .notDirectory)
    let copied = try Data(contentsOf: resolved)
    #expect(copied == Data([0x01, 0x02, 0x03]))

    let productionURL = SupacodePaths.repositoryIconFileURL(
      filename: filename, repositoryRootURL: fixture.repoRoot.url
    )
    #expect(!FileManager.default.fileExists(atPath: productionURL.path(percentEncoded: false)))
  }

  @Test func importImageNormalizesUppercaseExtension() throws {
    let fixture = makeStoreFixture()
    let source = ScratchDirectory(prefix: "prowl-icon-source")
    let sourceFile = try writeSourceFile(in: source, extension: "PNG")

    let filename = try fixture.store.importImage(sourceFile, fixture.repoRoot.url)
    #expect(filename.hasSuffix(".png"))
  }

  @Test func importImageAcceptsSVG() throws {
    let fixture = makeStoreFixture()
    let source = ScratchDirectory(prefix: "prowl-icon-source")
    let sourceFile = try writeSourceFile(in: source, extension: "svg")

    let filename = try fixture.store.importImage(sourceFile, fixture.repoRoot.url)
    #expect(filename.hasSuffix(".svg"))
  }

  @Test func importImageAcceptsArbitraryImageExtensions() throws {
    // The store no longer enforces a PNG/SVG whitelist — the file
    // picker filters down to image UTTypes already, and anything
    // that NSImage can't decode falls back to a placeholder at
    // render time. JPG / WebP / HEIC / GIF / TIFF / etc. all flow
    // through the same byte-copy path and round-trip through
    // `repositoryIconFileURL` like PNG does.
    let fixture = makeStoreFixture()

    for ext in ["jpg", "jpeg", "webp", "heic", "gif", "tiff", "bmp"] {
      let source = ScratchDirectory(prefix: "prowl-icon-source")
      let sourceFile = try writeSourceFile(in: source, extension: ext)
      let filename = try fixture.store.importImage(sourceFile, fixture.repoRoot.url)
      #expect(filename.hasSuffix(".\(ext)"))
    }
  }

  @Test func importImageHandlesFileWithNoExtension() throws {
    // Defensive: a dragged-in file without an extension shouldn't
    // crash the importer. The destination filename gets a generic
    // fallback so the round-trip still works.
    let fixture = makeStoreFixture()
    let source = ScratchDirectory(prefix: "prowl-icon-source")
    let sourceFile = source.url.appending(path: "icon", directoryHint: .notDirectory)
    try Data([0xDE, 0xAD]).write(to: sourceFile)

    let filename = try fixture.store.importImage(sourceFile, fixture.repoRoot.url)
    #expect(!filename.isEmpty)
  }

  @Test func importImageCreatesIconsDirectoryWhenMissing() throws {
    let fixture = makeStoreFixture()
    // Don't pre-create the icons directory — importImage should make
    // it itself, otherwise first-time imports would fail.
    let source = ScratchDirectory(prefix: "prowl-icon-source")
    let sourceFile = try writeSourceFile(in: source, extension: "png")

    _ = try fixture.store.importImage(sourceFile, fixture.repoRoot.url)

    let iconsDir = fixture.iconsDirectory()
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: iconsDir.path(percentEncoded: false), isDirectory: &isDirectory
    )
    #expect(exists)
    #expect(isDirectory.boolValue)
  }

  @Test func importImageGeneratesUniqueFilenamePerCall() throws {
    let fixture = makeStoreFixture()
    let source = ScratchDirectory(prefix: "prowl-icon-source")
    let sourceFile = try writeSourceFile(in: source, extension: "png")

    let first = try fixture.store.importImage(sourceFile, fixture.repoRoot.url)
    let second = try fixture.store.importImage(sourceFile, fixture.repoRoot.url)
    #expect(first != second)
  }

  // MARK: - exists

  @Test func existsReportsFalseWhenMissing() {
    let fixture = makeStoreFixture()
    #expect(!fixture.store.exists("nonexistent.png", fixture.repoRoot.url))
  }

  @Test func existsReportsTrueAfterImport() throws {
    let fixture = makeStoreFixture()
    let source = ScratchDirectory(prefix: "prowl-icon-source")
    let sourceFile = try writeSourceFile(in: source, extension: "png")
    let filename = try fixture.store.importImage(sourceFile, fixture.repoRoot.url)
    #expect(fixture.store.exists(filename, fixture.repoRoot.url))
  }

  // MARK: - remove

  @Test func removeDeletesImportedFile() throws {
    let fixture = makeStoreFixture()
    let source = ScratchDirectory(prefix: "prowl-icon-source")
    let sourceFile = try writeSourceFile(in: source, extension: "png")
    let filename = try fixture.store.importImage(sourceFile, fixture.repoRoot.url)

    try fixture.store.remove(filename, fixture.repoRoot.url)
    #expect(!fixture.store.exists(filename, fixture.repoRoot.url))
  }

  @Test func removeIsIdempotent() throws {
    // Reset / replace flows can call remove repeatedly; missing files
    // shouldn't throw or the reducer would have to track existence.
    let fixture = makeStoreFixture()
    try fixture.store.remove("never-existed.png", fixture.repoRoot.url)
  }
}
