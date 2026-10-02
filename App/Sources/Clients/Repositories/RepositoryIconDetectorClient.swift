import Dependencies
import Foundation

/// Dependency wrapper around `RepositoryIconDetector` so reducer tests
/// can substitute fixture candidates without touching the file system.
nonisolated struct RepositoryIconDetectorClient: Sendable {
  var detect: @Sendable (_ rootURL: URL) async -> RepositoryIconCandidate?
}

nonisolated enum RepositoryIconDetectorClientKey: DependencyKey {
  static var liveValue: RepositoryIconDetectorClient {
    RepositoryIconDetectorClient(
      detect: { rootURL in
        await RepositoryIconDetector.detect(at: rootURL)
      }
    )
  }

  /// Detection is opportunistic; "found nothing" is the safe default
  /// for previews and for tests that don't care about icons.
  static var previewValue: RepositoryIconDetectorClient {
    RepositoryIconDetectorClient(detect: { _ in nil })
  }
  static var testValue: RepositoryIconDetectorClient {
    RepositoryIconDetectorClient(detect: { _ in nil })
  }
}

extension DependencyValues {
  nonisolated var repositoryIconDetector: RepositoryIconDetectorClient {
    get { self[RepositoryIconDetectorClientKey.self] }
    set { self[RepositoryIconDetectorClientKey.self] = newValue }
  }
}
