import Foundation
import UniformTypeIdentifiers

/// Folders that Finder or the Dock asked Prowl to open.
nonisolated enum FolderOpenRequest {
  /// The plain folders among `urls`. A package such as a workflow bundle or an app is a directory
  /// but not a folder, so it is not a project.
  static func folderURLs(in urls: [URL]) -> [URL] {
    urls.filter { url in
      guard url.isFileURL,
        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
      else { return false }
      return contentType.conforms(to: .folder)
    }
  }
}
