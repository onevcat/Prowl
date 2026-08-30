import AppKit
import SwiftUI

struct CloneRepositoryView: View {
  @State private var urlString = ""
  @State private var locationPath = Self.defaultClonePath
  @State private var isCloning = false
  @State private var errorMessage: String?
  let dismiss: () -> Void
  let onCloned: (URL) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Clone")
          .interfaceFont(size: 16, weight: .semibold)
        Text("Clone a remote repository into a local directory")
          .interfaceFont(size: 12.5)
          .foregroundStyle(.secondary)
      }

      Grid(alignment: .leading, verticalSpacing: 12) {
        GridRow {
          Text("URL:")
            .gridColumnAlignment(.trailing)
          TextField("Git Repository URL", text: $urlString)
            .textFieldStyle(.roundedBorder)
        }
        GridRow {
          Text("Location:")
          HStack(spacing: 6) {
            TextField("Clone destination", text: $locationPath)
              .textFieldStyle(.roundedBorder)
            Button {
              pickLocation()
            } label: {
              Image(systemName: "folder")
                .accessibilityHidden(true)
            }
            .accessibilityLabel("Choose clone destination")
            .help("Choose clone destination")
          }
        }
      }

      if let errorMessage {
        Text(errorMessage)
          .interfaceFont(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Clone") {
          performClone()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!isValidInput || isCloning)
      }
    }
    .padding(24)
    .frame(width: 460)
    .onAppear { prefillFromClipboard() }
    .disabled(isCloning)
    .overlay {
      if isCloning {
        VStack(spacing: 8) {
          ProgressView()
          Text("Cloning…")
            .interfaceFont(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
      }
    }
  }

  private var isValidInput: Bool {
    !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !locationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func prefillFromClipboard() {
    guard let content = NSPasteboard.general.string(forType: .string) else { return }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if Self.isGitURL(trimmed) {
      urlString = trimmed
    }
  }

  private func pickLocation() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      locationPath = url.path
    }
  }

  private func performClone() {
    guard let request = Self.cloneRequest(urlString: urlString, locationPath: locationPath) else {
      errorMessage = "Enter a valid clone URL and destination."
      return
    }

    isCloning = true
    errorMessage = nil

    Task {
      let error = await Self.runGitClone(url: request.url, destination: request.destination)
      isCloning = false
      if let error {
        errorMessage = error
      } else {
        dismiss()
        onCloned(request.destination)
      }
    }
  }

  static func cloneRequest(urlString: String, locationPath: String) -> CloneRequest? {
    let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedURL.isEmpty,
      let normalizedLocation = PathPolicy.normalizePath(locationPath, resolvingSymlinks: false)
    else {
      return nil
    }

    let destination = URL(fileURLWithPath: normalizedLocation, isDirectory: true)
      .appending(path: extractRepoName(from: trimmedURL), directoryHint: .isDirectory)
    return CloneRequest(url: trimmedURL, destination: destination)
  }

  /// Returns `nil` on success, or an error message on failure.
  static func runGitClone(url: String, destination: URL) async -> String? {
    await withCheckedContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = ["clone", "--", url, destination.path]
      process.standardOutput = FileHandle.nullDevice
      let errorLogURL = FileManager.default.temporaryDirectory
        .appending(path: "prowl-git-clone-\(UUID().uuidString).log", directoryHint: .notDirectory)

      guard FileManager.default.createFile(atPath: errorLogURL.path(percentEncoded: false), contents: nil),
        let errorHandle = try? FileHandle(forWritingTo: errorLogURL)
      else {
        continuation.resume(returning: "Unable to prepare clone log")
        return
      }

      process.standardError = errorHandle

      process.terminationHandler = { proc in
        try? errorHandle.close()
        defer {
          try? FileManager.default.removeItem(at: errorLogURL)
        }

        if proc.terminationStatus == 0 {
          continuation.resume(returning: nil)
        } else {
          let data = (try? Data(contentsOf: errorLogURL)) ?? Data()
          let msg =
            String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Clone failed"
          continuation.resume(returning: msg)
        }
      }

      do {
        try process.run()
      } catch {
        try? errorHandle.close()
        try? FileManager.default.removeItem(at: errorLogURL)
        continuation.resume(returning: error.localizedDescription)
      }
    }
  }

  static func isGitURL(_ string: String) -> Bool {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("git@") && trimmed.contains(":") { return true }

    guard let components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased()
    else {
      return false
    }

    if scheme == "https" || scheme == "http" {
      if components.path.hasSuffix(".git") { return true }
      let hosts = ["github.com", "gitlab.com", "bitbucket.org", "dev.azure.com", "gitee.com"]
      return components.host.map { hosts.contains($0.lowercased()) } ?? false
    }
    return scheme == "git" || scheme == "ssh"
  }

  static func extractRepoName(from urlString: String) -> String {
    var cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    while cleaned.hasSuffix("/") {
      cleaned.removeLast()
    }

    var name: String?
    if cleaned.contains(":") && !cleaned.contains("://") {
      let pathPart = cleaned.split(separator: ":", maxSplits: 1).last.map(String.init) ?? cleaned
      name = pathPart.split(separator: "/").last.map(String.init)
    } else {
      name =
        URLComponents(string: cleaned)?.path.split(separator: "/").last.map(String.init)
        ?? URL(string: cleaned)?.lastPathComponent
    }

    var resolvedName = name ?? cleaned
    if resolvedName.hasSuffix(".git") {
      resolvedName = String(resolvedName.dropLast(4))
    }
    return resolvedName.isEmpty ? "repository" : resolvedName
  }

  private static var defaultClonePath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let developer = home.appendingPathComponent("Developer")
    if FileManager.default.fileExists(atPath: developer.path) {
      return developer.path
    }
    return home.path
  }
}

extension CloneRepositoryView {
  struct CloneRequest: Equatable {
    let url: String
    let destination: URL
  }
}
