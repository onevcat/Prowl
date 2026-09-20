import ConcurrencyExtras
import Foundation

nonisolated struct GitExecutable: Sendable, Equatable {
  let url: URL
  let searchPath: String

  var environment: [String: String] {
    var values = ["PATH": searchPath, "LC_ALL": "C", "LANG": "C"]
    if let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
      values["DEVELOPER_DIR"] = developerDirectory
    }
    return values
  }

  var environmentArguments: [String] {
    var arguments = ["PATH=\(searchPath)", "LC_ALL=C", "LANG=C"]
    if let developerDirectory = environment["DEVELOPER_DIR"] {
      arguments.append("DEVELOPER_DIR=\(developerDirectory)")
    }
    return arguments
  }

  func run(_ arguments: [String], in directory: URL? = nil, shell: ShellClient = .live) async throws -> ShellOutput {
    try await shell.run(
      URL(fileURLWithPath: "/usr/bin/env"),
      environmentArguments + [url.path(percentEncoded: false)] + arguments, directory)
  }
}

actor GitExecutableResolver {
  static let shared = GitExecutableResolver()

  // Synchronous workflow observation must not discover executables on the main thread.
  nonisolated var cachedExecutable: GitExecutable? { cached.value }
  nonisolated private let cached = LockIsolated<GitExecutable?>(nil)
  private var inFlight: Task<GitExecutable, Error>?
  private let processPath: String
  private let fallbackPaths: [String]

  init(
    processPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
    fallbackPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
  ) {
    self.processPath = processPath
    self.fallbackPaths = fallbackPaths
  }

  func resolve(revalidate: Bool = false, shell: ShellClient = .live) async throws -> GitExecutable {
    if let inFlight { return try await inFlight.value }
    if !revalidate, let executable = cached.value { return executable }
    let previous = cached.value
    let task = Task {
      var diagnostics: [String] = []
      if let previous, await validate(previous, shell: shell, diagnostics: &diagnostics) {
        return previous
      }
      return try await discover(shell: shell, diagnostics: &diagnostics)
    }
    inFlight = task
    do {
      let executable = try await task.value
      cached.setValue(executable)
      inFlight = nil
      return executable
    } catch {
      cached.setValue(nil)
      inFlight = nil
      throw error
    }
  }

  private func discover(shell: ShellClient, diagnostics: inout [String]) async throws -> GitExecutable {
    var tried: Set<String> = []
    if let executable = await firstWorking(in: processPath, shell: shell, tried: &tried, diagnostics: &diagnostics) {
      return executable
    }
    let loginPath = try? await shell.runLogin(
      URL(fileURLWithPath: "/usr/bin/printenv"), ["PATH"], nil, log: false
    ).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let loginPath, !loginPath.isEmpty,
      let executable = await firstWorking(in: loginPath, shell: shell, tried: &tried, diagnostics: &diagnostics)
    {
      return executable
    }
    let fallback = (fallbackPaths + [processPath]).joined(separator: ":")
    if let executable = await firstWorking(in: fallback, shell: shell, tried: &tried, diagnostics: &diagnostics) {
      return executable
    }
    throw GitClientError.unavailable(details: diagnostics.joined(separator: "\n"))
  }

  private func firstWorking(
    in path: String, shell: ShellClient, tried: inout Set<String>, diagnostics: inout [String]
  ) async -> GitExecutable? {
    for directory in path.split(separator: ":") where directory.hasPrefix("/") {
      let url = URL(fileURLWithPath: String(directory)).appending(path: "git")
      // The same executable can need a different PATH for its helper programs.
      guard tried.insert("\(url.path)|\(path)").inserted,
        FileManager.default.isExecutableFile(atPath: url.path)
      else { continue }
      let searchPath = "\(directory):\(path)"
      let executable = GitExecutable(url: url, searchPath: searchPath)
      if await validate(executable, shell: shell, diagnostics: &diagnostics) { return executable }
    }
    return nil
  }

  private func validate(
    _ executable: GitExecutable, shell: ShellClient, diagnostics: inout [String]
  ) async -> Bool {
    do {
      let output = try await executable.run(["--version"], shell: shell)
      guard output.stdout.hasPrefix("git version ") else {
        diagnostics.append("\(executable.url.path): unexpected version output")
        return false
      }
      return true
    } catch {
      diagnostics.append("\(executable.url.path): \(error.localizedDescription)")
      return false
    }
  }
}
