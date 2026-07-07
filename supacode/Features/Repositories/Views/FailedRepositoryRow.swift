import AppKit
import SwiftUI

struct FailedRepositoryRow: View {
  let name: String
  let path: String
  let showFailure: () -> Void
  let updateRepository: () -> Void
  let removeRepository: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .foregroundStyle(.secondary)
        Text(path)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      Button("Show load failure", systemImage: "exclamationmark.triangle.fill", action: showFailure)
        .labelStyle(.iconOnly)
        .foregroundStyle(.red)
        .help("Show load failure")
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button("Update…", action: updateRepository)
        .help("Choose a replacement folder for this repository")
      Button("Remove Repository", action: removeRepository)
        .help("Remove repository ")
    }
    .selectionDisabled(true)
  }
}

@MainActor
enum FailedRepositoryPathPicker {
  static func present(
    for path: String,
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    onSelection: @escaping (URL) -> Void
  ) {
    let panel = NSOpenPanel()
    panel.directoryURL = initialDirectory(
      for: path,
      fileManager: fileManager,
      homeDirectory: homeDirectory
    )
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "Choose"
    panel.message = "Choose the repository folder that should replace this missing path."

    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      onSelection(url)
    }
  }

  static func initialDirectory(
    for path: String,
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    guard !path.isEmpty else {
      return homeDirectory.standardizedFileURL
    }

    var candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    while true {
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(
        atPath: candidate.path(percentEncoded: false),
        isDirectory: &isDirectory
      ),
        isDirectory.boolValue
      {
        return candidate
      }
      let parent = candidate.deletingLastPathComponent().standardizedFileURL
      guard parent != candidate else {
        return homeDirectory.standardizedFileURL
      }
      candidate = parent
    }
  }
}
