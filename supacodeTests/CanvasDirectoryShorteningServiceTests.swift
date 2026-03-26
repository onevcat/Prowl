import Foundation
import Testing

@testable import supacode

struct CanvasDirectoryShorteningServiceTests {
  @Test func shortensIntermediateSegmentsToShortestUniquePrefix() async {
    let fileSystem = StubCanvasDirectoryFileSystem(
      canonicalPaths: [
        "~": "/Users/test",
        "~/project/feature": "/Users/test/project/feature",
      ],
      parentIdentities: [
        "/Users/test": "home-parent",
      ],
      siblingSequences: [
        "/Users/test": [["project", "playground", "pictures"]],
      ]
    )

    let service = CanvasDirectoryShorteningService(
      fileSystem: fileSystem,
      policy: CanvasDirectoryShorteningPolicy(),
      homePath: "/Users/test"
    )

    let shortened = await service.shortenedDisplayPath(for: "~/project/feature")

    #expect(shortened == "~/pr/feature")
  }

  @Test func keepsAnchorAndLastSegmentUnshortened() async {
    let fileSystem = StubCanvasDirectoryFileSystem(
      canonicalPaths: [
        "/tmp/workspace/module": "/tmp/workspace/module",
      ],
      parentIdentities: [
        "/": "root-parent",
        "/tmp": "tmp-parent",
      ],
      siblingSequences: [
        "/": [["tmp", "usr", "opt"]],
        "/tmp": [["workspace", "docs"]],
      ]
    )

    let service = CanvasDirectoryShorteningService(
      fileSystem: fileSystem,
      policy: CanvasDirectoryShorteningPolicy(),
      homePath: "/Users/test"
    )

    let shortened = await service.shortenedDisplayPath(for: "/tmp/workspace/module")

    #expect(shortened == "/t/w/module")
  }

  @Test func v1UsesEmptyDelimiterBehavior() async {
    let fileSystem = StubCanvasDirectoryFileSystem(
      canonicalPaths: [
        "~": "/Users/test",
        "~/alpha/project": "/Users/test/alpha/project",
      ],
      parentIdentities: [
        "/Users/test": "home-parent",
      ],
      siblingSequences: [
        "/Users/test": [["alpha", "alpine"]],
      ]
    )

    let service = CanvasDirectoryShorteningService(
      fileSystem: fileSystem,
      policy: CanvasDirectoryShorteningPolicy(shortenDirLength: 1, delimiter: ""),
      homePath: "/Users/test"
    )

    let shortened = await service.shortenedDisplayPath(for: "~/alpha/project")

    #expect(shortened == "~/alph/project")
  }

  @Test func canonicalizesTildePathBeforeProbe() async {
    let fileSystem = StubCanvasDirectoryFileSystem(
      canonicalPaths: [
        "~": "/Users/test",
        "~/workspace/project": "/Users/test/workspace/project",
      ],
      parentIdentities: [
        "/Users/test": "home-parent",
      ],
      siblingSequences: [
        "/Users/test": [["workspace", "work"]],
      ]
    )

    let service = CanvasDirectoryShorteningService(
      fileSystem: fileSystem,
      policy: CanvasDirectoryShorteningPolicy(),
      homePath: "/Users/test"
    )

    _ = await service.shortenedDisplayPath(for: "~/workspace/project")

    let probedParents = await fileSystem.observedProbedParents()
    #expect(probedParents == ["/Users/test"])
  }

  @Test func cachesByParentPathIdentityAndSiblingsHash() async {
    let fileSystem = StubCanvasDirectoryFileSystem(
      canonicalPaths: [
        "~": "/Users/test",
        "~/project/feature": "/Users/test/project/feature",
      ],
      parentIdentities: [
        "/Users/test": "home-parent",
      ],
      siblingSequences: [
        "/Users/test": [
          ["project", "playground"],
          ["project", "prototype"],
        ],
      ]
    )

    let service = CanvasDirectoryShorteningService(
      fileSystem: fileSystem,
      policy: CanvasDirectoryShorteningPolicy(),
      homePath: "/Users/test"
    )

    let first = await service.shortenedDisplayPath(for: "~/project/feature")
    let second = await service.shortenedDisplayPath(for: "~/project/feature")

    #expect(first == "~/pr/feature")
    #expect(second == "~/proj/feature")
  }

  @Test func bypassesCacheWhenParentIdentityUnavailable() async {
    let fileSystem = StubCanvasDirectoryFileSystem(
      canonicalPaths: [
        "~": "/Users/test",
        "~/alpha/leaf": "/Users/test/alpha/leaf",
      ],
      parentIdentities: [:],
      parentsWithoutIdentity: ["/Users/test"],
      siblingSequences: [
        "/Users/test": [
          ["alpha", "alpine"],
          ["alpha", "beta"],
        ],
      ]
    )

    let service = CanvasDirectoryShorteningService(
      fileSystem: fileSystem,
      policy: CanvasDirectoryShorteningPolicy(),
      homePath: "/Users/test"
    )

    let first = await service.shortenedDisplayPath(for: "~/alpha/leaf")
    let second = await service.shortenedDisplayPath(for: "~/alpha/leaf")

    #expect(first == "~/alph/leaf")
    #expect(second == "~/a/leaf")
  }

  @Test func fallsBackToNormalizedPathWhenProbeFails() async {
    let fileSystem = StubCanvasDirectoryFileSystem(
      canonicalPaths: [
        "~": "/Users/test",
        "~/project/feature": "/Users/test/project/feature",
      ],
      parentIdentities: [
        "/Users/test": "home-parent",
      ],
      siblingSequences: [
        "/Users/test": [["project", "playground"]],
      ],
      failingParents: ["/Users/test"]
    )

    let service = CanvasDirectoryShorteningService(
      fileSystem: fileSystem,
      policy: CanvasDirectoryShorteningPolicy(),
      homePath: "/Users/test"
    )

    let shortened = await service.shortenedDisplayPath(for: "~/project/feature")

    #expect(shortened == "~/project/feature")
  }
}

private actor StubCanvasDirectoryFileSystem: CanvasDirectoryFileSystem {
  enum StubError: Error {
    case unreadableParent
  }

  private let canonicalPaths: [String: String]
  private let parentIdentities: [String: String]
  private let parentsWithoutIdentity: Set<String>
  private var siblingSequences: [String: [[String]]]
  private let failingParents: Set<String>
  private var probedParents: [String] = []

  init(
    canonicalPaths: [String: String],
    parentIdentities: [String: String],
    parentsWithoutIdentity: Set<String> = [],
    siblingSequences: [String: [[String]]],
    failingParents: Set<String> = []
  ) {
    self.canonicalPaths = canonicalPaths
    self.parentIdentities = parentIdentities
    self.parentsWithoutIdentity = parentsWithoutIdentity
    self.siblingSequences = siblingSequences
    self.failingParents = failingParents
  }

  func canonicalPath(for normalizedDisplayPath: String, homePath: String) async -> String? {
    canonicalPaths[normalizedDisplayPath]
  }

  func parentIdentity(forCanonicalParentPath parentPath: String) async -> String? {
    guard !parentsWithoutIdentity.contains(parentPath) else { return nil }
    return parentIdentities[parentPath]
  }

  func siblingDirectoryNames(inCanonicalParentPath parentPath: String) async throws -> [String] {
    probedParents.append(parentPath)
    if failingParents.contains(parentPath) {
      throw StubError.unreadableParent
    }

    guard var sequences = siblingSequences[parentPath], !sequences.isEmpty else {
      return []
    }

    if sequences.count == 1 {
      return sequences[0]
    }

    let result = sequences.removeFirst()
    siblingSequences[parentPath] = sequences
    return result
  }

  func observedProbedParents() -> [String] {
    probedParents
  }
}
