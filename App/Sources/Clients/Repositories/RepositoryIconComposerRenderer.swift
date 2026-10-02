import AppKit
import Foundation
import QuickLookThumbnailing

/// Flattens an Icon Composer `.icon` bundle into a plain PNG via the
/// system QuickLook thumbnail pipeline. The bundle format is layered
/// (background fill, glass layers, per-appearance specializations), so
/// compositing ourselves would misrepresent the icon — QuickLook's own
/// renderer is the source of truth. Only a real `.thumbnail`
/// representation is accepted: on machines without the Icon Composer
/// QuickLook support the request fails and detection just falls
/// through to the asset-catalog probe.
nonisolated enum RepositoryIconComposerRenderer {
  static func render(_ iconBundleURL: URL) async -> URL? {
    let request = QLThumbnailGenerator.Request(
      fileAt: iconBundleURL,
      size: CGSize(width: 512, height: 512),
      scale: 2,
      representationTypes: .thumbnail
    )
    guard
      let representation = try? await QLThumbnailGenerator.shared
        .generateBestRepresentation(for: request)
    else {
      return nil
    }
    let bitmap = NSBitmapImageRep(cgImage: representation.cgImage)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return nil
    }
    let destination = FileManager.default.temporaryDirectory
      .appending(path: "prowl-icon-composer-\(UUID().uuidString).png", directoryHint: .notDirectory)
    do {
      try data.write(to: destination, options: [.atomic])
    } catch {
      return nil
    }
    return destination
  }
}
