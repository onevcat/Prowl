import ComposableArchitecture
import Foundation
import SwiftUI

/// Shared in-memory cache for GitHub owner names resolved from repository
/// root URLs. Once resolved, the owner name is used to construct the
/// public GitHub avatar URL: `https://github.com/{owner}.png?size=64`.
@MainActor
final class RemoteAvatarStore: Observable {
  static let shared = RemoteAvatarStore()

  /// Cache: repository root URL path → resolved GitHub owner name.
  private(set) var ownerByRepositoryRoot: [String: String] = [:]

  /// Tracks in-flight resolution tasks.
  private var inFlight: [String: Task<Void, Never>] = [:]

  private init() {}

  /// Returns the GitHub avatar URL for a repository, or `nil` if the
  /// owner hasn't been resolved yet.
  func avatarURL(forRepositoryRoot rootURL: URL) -> URL? {
    let key = rootURL.path(percentEncoded: false)
    guard let owner = ownerByRepositoryRoot[key] else { return nil }
    return Self.githubAvatarURL(for: owner)
  }

  /// Constructs the public GitHub avatar URL for a given owner.
  /// This URL doesn't require authentication and works for both users
  /// and organizations.
  nonisolated static func githubAvatarURL(for owner: String) -> URL? {
    URL(string: "https://github.com/\(owner).png?size=64")
  }

  /// Kicks off owner resolution for a repository root URL. The resolution
  /// parses the git remote URL to extract the GitHub owner (user or org).
  func ensureOwnerResolved(
    forRepositoryRoot rootURL: URL,
    gitClient: GitClientDependency
  ) {
    let key = rootURL.path(percentEncoded: false)
    if ownerByRepositoryRoot[key] != nil || inFlight[key] != nil {
      return
    }

    let task = Task {
      // Resolve GitHub owner from git remote (origin).
      if let remoteInfo = await gitClient.remoteInfo(rootURL) {
        await MainActor.run {
          self.ownerByRepositoryRoot[key] = remoteInfo.owner
          self.inFlight[key] = nil
        }
        return
      }
      // Mark as failed (store empty string to avoid retrying).
      await MainActor.run {
        self.ownerByRepositoryRoot[key] = ""
        self.inFlight[key] = nil
      }
    }
    inFlight[key] = task
  }

  func clear() {
    for task in inFlight.values {
      task.cancel()
    }
    inFlight.removeAll()
    ownerByRepositoryRoot.removeAll()
  }
}
