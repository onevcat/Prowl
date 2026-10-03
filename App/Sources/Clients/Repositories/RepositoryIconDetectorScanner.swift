import AppKit
import Foundation
import ImageIO

extension RepositoryIconDetector {
  /// Bounded, deterministic file-system access for the detector. All
  /// probes go through this one type so the traversal budget, symlink
  /// policy, containment check, and image validation can't drift apart
  /// between platforms.
  nonisolated final class Scanner {
    /// Directories that never contain product icons but often contain
    /// tens of thousands of entries. Compared lowercased.
    private static let skippedDirectoryNames: Set<String> = [
      ".git", ".build", ".dart_tool", ".gradle", ".idea", ".svn", ".vscode",
      "build", "carthage", "deriveddata", "dist", "node_modules", "out",
      "pods", "target", "vendor",
    ]
    private static let allowedImageExtensions: Set<String> = [
      "png", "jpg", "jpeg", "webp", "ico", "icns", "svg",
    ]
    /// Widest width:height ratio the near-square gate accepts; wide
    /// wordmark logos and social banners fail this on purpose.
    private static let maxNearSquareAspectRatio = 1.5
    private static let maxImageBytes = 5 * 1024 * 1024
    private static let maxRasterPixelDimension = 4096
    private static let minRasterPixelDimension = 16
    private static let maxVisitedEntries = 5000
    private static let maxModuleDirectories = 50

    let rootURL: URL
    private let resolvedRootPath: String
    private let fileManager: FileManager
    private var remainingEntries = Scanner.maxVisitedEntries

    init(rootURL: URL, fileManager: FileManager) {
      self.rootURL = rootURL
      self.resolvedRootPath = rootURL.resolvingSymlinksInPath().path(percentEncoded: false)
      self.fileManager = fileManager
    }

    /// Lowercased shallow listing, mirroring `WorktreeProjectKind`'s
    /// marker matching. Empty when the directory can't be read.
    func entryNames(of directory: URL) -> Set<String> {
      guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
      else {
        return []
      }
      return Set(entries.map { $0.lowercased() })
    }

    /// Sorted plain subdirectory names (no symlinks, skip list applied),
    /// capped so a flat repo with thousands of folders stays cheap.
    func subdirectoryNames(of directory: URL) -> [String] {
      Array(childDirectories(of: directory).map(\.lastPathComponent).prefix(Scanner.maxModuleDirectories))
    }

    func directoryExists(_ url: URL) -> Bool {
      var isDirectory: ObjCBool = false
      let exists = fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
      return exists && isDirectory.boolValue
    }

    /// Breadth-first search for directories whose name matches
    /// `lowercasedName`, ordered nearest-to-root first and
    /// lexicographically within one depth. Respects the shared entry
    /// budget and cooperative cancellation.
    func findDirectories(named lowercasedName: String, under directory: URL, maxDepth: Int) -> [URL] {
      findDirectories(under: directory, maxDepth: maxDepth) {
        $0.lastPathComponent.lowercased() == lowercasedName
      }
    }

    /// Same search keyed on a directory extension (e.g. Icon Composer
    /// `.icon` bundles, which carry arbitrary base names).
    func findDirectories(withExtension lowercasedExtension: String, under directory: URL, maxDepth: Int) -> [URL] {
      findDirectories(under: directory, maxDepth: maxDepth) {
        $0.pathExtension.lowercased() == lowercasedExtension
      }
    }

    private func findDirectories(
      under directory: URL,
      maxDepth: Int,
      matches: (URL) -> Bool
    ) -> [URL] {
      var found: [URL] = []
      var frontier = [directory]
      var depth = 0
      while !frontier.isEmpty, depth < maxDepth, remainingEntries > 0, !Task.isCancelled {
        var next: [URL] = []
        for parent in frontier {
          for child in childDirectories(of: parent) {
            if matches(child) {
              found.append(child)
            } else {
              next.append(child)
            }
          }
        }
        frontier = next
        depth += 1
      }
      return found
    }

    /// Reads at most `limit` bytes; refuses files that would exceed it
    /// rather than truncating a manifest into valid-looking JSON.
    func boundedContents(of url: URL, limit: Int) -> Data? {
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        values.isRegularFile == true,
        let fileSize = values.fileSize, fileSize <= limit
      else {
        return nil
      }
      return try? Data(contentsOf: url)
    }

    /// Full validation pipeline for a candidate image. Returns the URL
    /// when the file is safe to import: contained in the repository
    /// after resolving symlinks, a regular file of bounded size, an
    /// allowed format, and actually decodable at a sane pixel size.
    func validatedImage(at url: URL) -> URL? {
      validatedImageSize(at: url) == nil ? nil : url
    }

    /// `validatedImage` plus a near-square gate: wide wordmark logos
    /// and banner images make terrible sidebar icons, so the generic
    /// fallback tier refuses them.
    func validatedNearSquareImage(at url: URL) -> URL? {
      guard let size = validatedImageSize(at: url), size.width > 0, size.height > 0 else {
        return nil
      }
      let ratio = max(size.width, size.height) / min(size.width, size.height)
      return ratio <= Scanner.maxNearSquareAspectRatio ? url : nil
    }

    private func validatedImageSize(at url: URL) -> CGSize? {
      let fileExtension = url.pathExtension.lowercased()
      guard Scanner.allowedImageExtensions.contains(fileExtension) else { return nil }
      let resolved = url.resolvingSymlinksInPath()
      let resolvedPath = resolved.path(percentEncoded: false)
      guard resolvedPath.hasPrefix(resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/")
      else {
        return nil
      }
      guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        values.isRegularFile == true,
        let fileSize = values.fileSize,
        fileSize > 0, fileSize <= Scanner.maxImageBytes
      else {
        return nil
      }
      if fileExtension == "svg" {
        return decodableSVGSize(at: resolved)
      }
      return decodableRasterSize(at: resolved)
    }

    // MARK: - Private

    private func childDirectories(of directory: URL) -> [URL] {
      guard remainingEntries > 0,
        let entries = try? fileManager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles]
        )
      else {
        return []
      }
      remainingEntries -= entries.count
      return
        entries
        .filter { url in
          let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          guard values?.isDirectory == true, values?.isSymbolicLink != true else { return false }
          return !Scanner.skippedDirectoryNames.contains(url.lastPathComponent.lowercased())
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Cheap structural sniff plus a real decode. `NSImage` is the same
    /// renderer the app uses later, so a pass here guarantees the icon
    /// won't turn into the missing-file placeholder. The declared
    /// canvas must be finite and within the same pixel ceiling as
    /// rasters — vectors have no quality floor, so only the upper
    /// bound applies. A final rasterization pass rejects SVGs that
    /// load fine but draw nothing.
    private func decodableSVGSize(at url: URL) -> CGSize? {
      guard let prefix = boundedContents(of: url, limit: Scanner.maxImageBytes),
        let head = String(data: prefix.prefix(4096), encoding: .utf8),
        head.localizedCaseInsensitiveContains("<svg")
      else {
        return nil
      }
      guard let image = NSImage(contentsOf: url) else { return nil }
      let size = image.size
      let ceiling = CGFloat(Scanner.maxRasterPixelDimension)
      guard size.width.isFinite, size.height.isFinite,
        size.width > 0, size.height > 0,
        size.width <= ceiling, size.height <= ceiling
      else {
        return nil
      }
      return rendersVisiblePixels(image) ? size : nil
    }

    /// CoreSVG ignores embedded `<style>` blocks, so a favicon that
    /// leaves `fill="none"` on the root and colors its paths via CSS
    /// (Astro's default favicon, GitHub's dark-mode favicon) loads
    /// with a valid canvas yet rasterizes fully transparent. The only
    /// reliable gate is to actually draw it and look for coverage.
    private func rendersVisiblePixels(_ image: NSImage) -> Bool {
      let sample = 32
      guard
        let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: sample,
          pixelsHigh: sample,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: 0,
          bitsPerPixel: 0
        ),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
      else {
        return false
      }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      image.draw(in: NSRect(x: 0, y: 0, width: sample, height: sample))
      NSGraphicsContext.restoreGraphicsState()
      guard let pixels = bitmap.bitmapData else { return false }
      for row in 0..<sample {
        let rowStart = pixels + row * bitmap.bytesPerRow
        for column in 0..<sample where rowStart[column * 4 + 3] > 25 {
          return true
        }
      }
      return false
    }

    /// Metadata-only probe via ImageIO — no bitmap is decompressed, so
    /// a decompression bomb can't hurt us; the pixel cap keeps later
    /// rendering bounded too.
    private func decodableRasterSize(at url: URL) -> CGSize? {
      let options = [kCGImageSourceShouldCache: false] as CFDictionary
      guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
        CGImageSourceGetCount(source) > 0,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        (Scanner.minRasterPixelDimension...Scanner.maxRasterPixelDimension).contains(width),
        (Scanner.minRasterPixelDimension...Scanner.maxRasterPixelDimension).contains(height)
      else {
        return nil
      }
      return CGSize(width: width, height: height)
    }
  }
}
