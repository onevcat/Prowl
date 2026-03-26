import Foundation

actor CanvasDirectoryShorteningService {
  private struct CacheKey: Hashable, Sendable {
    let parentCanonicalPath: String
    let parentIdentity: String
    let siblingsHash: UInt64
    let segmentName: String
  }

  private enum Anchor: Sendable {
    case root
    case home
  }

  private struct ParsedDisplayPath: Sendable {
    let anchor: Anchor
    let segments: [String]
  }

  private struct ParentProbeResult: Sendable {
    let identity: String?
    let siblings: [String]
    let siblingsHash: UInt64
  }

  private let fileSystem: any CanvasDirectoryFileSystem
  private let policy: CanvasDirectoryShorteningPolicy
  private let homePath: String
  private var segmentCache: [CacheKey: String] = [:]
  private var cachedCanonicalHomePath: String?

  init(
    fileSystem: any CanvasDirectoryFileSystem,
    policy: CanvasDirectoryShorteningPolicy,
    homePath: String
  ) {
    self.fileSystem = fileSystem
    self.policy = policy
    self.homePath = homePath
  }

  func shortenedDisplayPath(for normalizedDisplayPath: String?) async -> String? {
    guard let normalizedDisplayPath else { return nil }
    let trimmed = normalizedDisplayPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let parsed = parseDisplayPath(trimmed) else { return trimmed }
    guard !parsed.segments.isEmpty else { return trimmed }

    let preservedTailCount = min(policy.shortenDirLength, parsed.segments.count)
    let shortenableCount = parsed.segments.count - preservedTailCount
    guard shortenableCount > 0 else { return trimmed }

    guard
      let canonicalPath = await fileSystem.canonicalPath(for: trimmed, homePath: homePath),
      let canonicalSegments = await canonicalSegments(for: parsed, canonicalPath: canonicalPath),
      canonicalSegments.count == parsed.segments.count,
      let startingParentPath = await startingParentPath(for: parsed)
    else {
      return trimmed
    }

    var shortenedSegments = parsed.segments
    var parentPath = startingParentPath
    do {
      for index in shortenedSegments.indices {
        if index < shortenableCount {
          let probe = try await probeParent(parentPath)
          shortenedSegments[index] = shortenedSegment(
            shortenedSegments[index],
            parentPath: parentPath,
            parentIdentity: probe.identity,
            siblings: probe.siblings,
            siblingsHash: probe.siblingsHash
          )
        }
        parentPath = appendPathComponent(canonicalSegments[index], to: parentPath)
      }
    } catch {
      return trimmed
    }

    return assemblePath(anchor: parsed.anchor, segments: shortenedSegments)
  }

  private func parseDisplayPath(_ path: String) -> ParsedDisplayPath? {
    if path == "/" {
      return ParsedDisplayPath(anchor: .root, segments: [])
    }
    if path.hasPrefix("/") {
      return ParsedDisplayPath(anchor: .root, segments: splitPath(path))
    }
    if path == "~" {
      return ParsedDisplayPath(anchor: .home, segments: [])
    }
    if path.hasPrefix("~/") {
      let suffix = String(path.dropFirst(2))
      return ParsedDisplayPath(anchor: .home, segments: splitPath(suffix))
    }
    return nil
  }

  private func splitPath(_ path: String) -> [String] {
    path.split(separator: "/").map(String.init)
  }

  private func canonicalSegments(for parsed: ParsedDisplayPath, canonicalPath: String) async -> [String]? {
    let canonicalComponents = splitPath(canonicalPath)
    switch parsed.anchor {
    case .root:
      guard canonicalComponents.count == parsed.segments.count else { return nil }
      return canonicalComponents
    case .home:
      guard let canonicalHomePath = await canonicalHomePath() else { return nil }
      let homeComponents = splitPath(canonicalHomePath)
      guard canonicalComponents.starts(with: homeComponents) else { return nil }
      let relativeComponents = Array(canonicalComponents.dropFirst(homeComponents.count))
      guard relativeComponents.count == parsed.segments.count else { return nil }
      return relativeComponents
    }
  }

  private func startingParentPath(for parsed: ParsedDisplayPath) async -> String? {
    switch parsed.anchor {
    case .root:
      return "/"
    case .home:
      return await canonicalHomePath()
    }
  }

  private func canonicalHomePath() async -> String? {
    if let cachedCanonicalHomePath {
      return cachedCanonicalHomePath
    }
    let canonical = await fileSystem.canonicalPath(for: "~", homePath: homePath)
    cachedCanonicalHomePath = canonical
    return canonical
  }

  private func probeParent(_ parentPath: String) async throws -> ParentProbeResult {
    let parentIdentity = await fileSystem.parentIdentity(forCanonicalParentPath: parentPath)
    let siblings = try await fileSystem.siblingDirectoryNames(inCanonicalParentPath: parentPath).sorted()
    return ParentProbeResult(
      identity: parentIdentity,
      siblings: siblings,
      siblingsHash: siblingsHash(for: siblings)
    )
  }

  private func shortenedSegment(
    _ segment: String,
    parentPath: String,
    parentIdentity: String?,
    siblings: [String],
    siblingsHash: UInt64
  ) -> String {
    if let parentIdentity {
      let key = CacheKey(
        parentCanonicalPath: parentPath,
        parentIdentity: parentIdentity,
        siblingsHash: siblingsHash,
        segmentName: segment
      )
      if let cached = segmentCache[key] {
        return cached
      }
      let shortened = uniquePrefix(for: segment, among: siblings)
      segmentCache[key] = shortened
      return shortened
    }

    return uniquePrefix(for: segment, among: siblings)
  }

  private func uniquePrefix(for segment: String, among siblings: [String]) -> String {
    guard !segment.isEmpty else { return segment }
    let candidates = siblings.isEmpty ? [segment] : siblings

    for prefixLength in 1...segment.count {
      let prefix = String(segment.prefix(prefixLength))
      let matchCount = candidates.filter { $0.hasPrefix(prefix) }.count
      guard matchCount == 1 else { continue }
      guard prefixLength < segment.count else { return segment }
      return policy.delimiter.isEmpty ? prefix : "\(prefix)\(policy.delimiter)"
    }

    return segment
  }

  private func siblingsHash(for siblings: [String]) -> UInt64 {
    // Stable FNV-1a hash to keep cache keys deterministic across launches.
    var hash: UInt64 = 1469598103934665603
    let prime: UInt64 = 1099511628211
    for sibling in siblings {
      for byte in sibling.utf8 {
        hash ^= UInt64(byte)
        hash &*= prime
      }
      hash ^= UInt64(UInt8(ascii: "/"))
      hash &*= prime
    }
    return hash
  }

  private func appendPathComponent(_ component: String, to parentPath: String) -> String {
    URL(filePath: parentPath, directoryHint: .isDirectory)
      .appending(path: component, directoryHint: .isDirectory)
      .path(percentEncoded: false)
  }

  private func assemblePath(anchor: Anchor, segments: [String]) -> String {
    switch anchor {
    case .root:
      return segments.isEmpty ? "/" : "/\(segments.joined(separator: "/"))"
    case .home:
      return segments.isEmpty ? "~" : "~/\(segments.joined(separator: "/"))"
    }
  }
}
