import ComposableArchitecture
import Foundation

/// Automatic repository icon detection lifecycle. Scans run only for
/// repositories newly added in the current operation, at utility
/// priority, and never block loading or selection. A result commits
/// only when the repository still exists, detection is still enabled,
/// and no manual icon or explicit clear got there first.
extension RepositoriesFeature {
  /// Adds are interactive and small; a hard cap keeps a bulk drag-in
  /// from fanning out unbounded file-system scans.
  static let maxIconDetectionsPerAdd = 8

  /// One shared cancellation umbrella over every in-flight scan, so a
  /// global opt-out cancels them all without per-repo bookkeeping.
  static let iconDetectionUmbrellaID = "repositories.iconDetection"

  /// Spawns one cancellable, utility-priority detection per eligible
  /// newly added repository. Workspace containers are never scanned;
  /// repositories with any existing icon or a recorded suppression are
  /// skipped up front. A scan that finds nothing ends silently.
  func iconDetectionEffects(for newRepositories: [Repository]) -> [Effect<Action>] {
    @Shared(.settingsFile) var settingsFile
    guard settingsFile.global.detectRepositoryIconsAutomatically else { return [] }
    @Shared(.repositoryAppearances) var appearances
    var effects: [Effect<Action>] = []
    for repository in newRepositories.prefix(Self.maxIconDetectionsPerAdd) {
      guard repository.workspace == nil else { continue }
      let appearance = appearances[repository.id] ?? .empty
      guard appearance.icon == nil, !appearance.iconDetectionSuppressed else { continue }
      let repositoryID = repository.id
      let rootURL = repository.rootURL
      let detector = repositoryIconDetector
      let assetStore = repositoryIconAssetStore
      effects.append(
        .run(priority: .utility) { send in
          guard let candidate = await detector.detect(rootURL), !Task.isCancelled else { return }
          let filename = try? assetStore.importImage(candidate.imageURL, rootURL)
          if candidate.ownsImageFile {
            // Detector-produced temp artifact (Icon Composer render):
            // delete it whether or not the import succeeded.
            try? FileManager.default.removeItem(at: candidate.imageURL)
          }
          guard let filename else { return }
          await send(
            .repositoryManagement(.repositoryIconDetected(repositoryID, filename: filename))
          )
        }
        .cancellable(id: CancelID.iconDetection(repositoryID), cancelInFlight: true)
        .cancellable(id: Self.iconDetectionUmbrellaID)
      )
    }
    return effects
  }

  /// Commit point for a successful scan. All guards re-run against the
  /// current world because the scan raced user actions: the repository
  /// may be gone, detection may have been disabled, and the user may
  /// have picked or cleared an icon. On any failed guard the imported
  /// asset is deleted instead of committed.
  func reduceIconDetected(
    state: inout State,
    repositoryID: Repository.ID,
    filename: String
  ) -> Effect<Action> {
    @Shared(.settingsFile) var settingsFile
    @Shared(.repositoryAppearances) var appearances
    let repository = state.repositories[id: repositoryID]
    let appearance = appearances[repositoryID] ?? .empty
    guard repository != nil,
      settingsFile.global.detectRepositoryIconsAutomatically,
      appearance.icon == nil,
      !appearance.iconDetectionSuppressed
    else {
      let rootURL = repository?.rootURL ?? URL(fileURLWithPath: repositoryID, isDirectory: true)
      let assetStore = repositoryIconAssetStore
      return .run { _ in
        try? assetStore.remove(filename, rootURL)
      }
    }
    $appearances.withLock {
      var updated = $0[repositoryID] ?? .empty
      updated.icon = .detectedImage(filename: filename)
      $0[repositoryID] = updated
    }
    return .none
  }

  /// Removal cleanup: cancel a pending scan and drop automatic
  /// detection artifacts (the detected image asset and the suppression
  /// flag) while preserving a user-selected icon and color, so a
  /// removed-and-re-added repository starts detection fresh.
  func iconDetectionRemovalEffect(
    repositoryID: Repository.ID,
    rootURL: URL?
  ) -> Effect<Action> {
    @Shared(.repositoryAppearances) var appearances
    var removedFilename: String?
    if let appearance = appearances[repositoryID] {
      var updated = appearance
      if case .detectedImage(let filename) = updated.icon {
        removedFilename = filename
        updated.icon = nil
      }
      updated.iconDetectionSuppressed = false
      if updated != appearance {
        $appearances.withLock {
          $0[repositoryID] = updated.isEmpty ? nil : updated
        }
      }
    }
    let cancel: Effect<Action> = .cancel(id: CancelID.iconDetection(repositoryID))
    guard let removedFilename else { return cancel }
    let resolvedRootURL = rootURL ?? URL(fileURLWithPath: repositoryID, isDirectory: true)
    let assetStore = repositoryIconAssetStore
    return .merge(
      cancel,
      .run { _ in
        try? assetStore.remove(removedFilename, resolvedRootURL)
      }
    )
  }
}
