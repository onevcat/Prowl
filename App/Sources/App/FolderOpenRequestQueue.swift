import Foundation

/// Keeps Finder/Dock requests until startup has restored the saved project list.
struct FolderOpenRequestQueue {
  private var pendingURLs: [URL] = []

  mutating func append(_ urls: [URL]) {
    pendingURLs.append(
      contentsOf: urls.filter { url in
        url.isFileURL && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      })
  }

  mutating func takePending(isReady: Bool) -> [URL] {
    guard isReady else { return [] }
    defer { pendingURLs.removeAll() }
    return pendingURLs
  }
}
