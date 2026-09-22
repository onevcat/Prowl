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

  func run(_ arguments: [String], in directory: URL? = nil, shell: ShellClient = .live) async throws
    -> ShellOutput
  {
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
  private var inFlight: Task<Void, Never>?
  private var discoveryID: UUID?
  private var waiters: [UUID: CheckedContinuation<GitExecutable, Error>] = [:]
  private let processPath: String
  private let fallbackPaths: [String]

  init(
    processPath: String = ProcessInfo.processInfo.environment["PATH"]
      ?? "/usr/bin:/bin:/usr/sbin:/sbin",
    fallbackPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
  ) {
    self.processPath = processPath
    self.fallbackPaths = fallbackPaths
  }

  func resolve(revalidate: Bool = false, shell: ShellClient = .probe()) async throws
    -> GitExecutable
  {
    try Task.checkCancellation()
    if inFlight == nil, !revalidate, let executable = cached.value { return executable }
    let waiterID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        waiters[waiterID] = continuation
        if inFlight == nil { startDiscovery(shell: shell) }
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterID) }
    }
  }

  private func startDiscovery(shell: ShellClient) {
    let id = UUID()
    discoveryID = id
    let previous = cached.value
    inFlight = Task {
      let result: Result<GitExecutable, Error>
      do {
        var diagnostics: [String] = []
        if let previous, try await validate(previous, shell: shell, diagnostics: &diagnostics) {
          result = .success(previous)
        } else {
          result = .success(try await discover(shell: shell, diagnostics: &diagnostics))
        }
      } catch {
        result = .failure(error)
      }
      finishDiscovery(id: id, result: result)
    }
  }

  private func finishDiscovery(id: UUID, result: Result<GitExecutable, Error>) {
    // A cancelled probe can finish after a new discovery has started.
    guard discoveryID == id else { return }
    cached.setValue(try? result.get())
    inFlight = nil
    discoveryID = nil
    let pending = waiters.values
    waiters = [:]
    for continuation in pending { continuation.resume(with: result) }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let continuation = waiters.removeValue(forKey: id) else { return }
    continuation.resume(throwing: CancellationError())
    if waiters.isEmpty {
      inFlight?.cancel()
      inFlight = nil
      discoveryID = nil
    }
  }

  private func discover(shell: ShellClient, diagnostics: inout [String]) async throws
    -> GitExecutable
  {
    var tried: Set<String> = []
    if let executable = try await firstWorking(
      in: processPath, shell: shell, tried: &tried, diagnostics: &diagnostics)
    {
      return executable
    }
    var loginPath: String?
    do {
      try Task.checkCancellation()
      loginPath = try await shell.runLogin(
        URL(fileURLWithPath: "/usr/bin/printenv"), ["PATH"], nil, log: false
      ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      try Task.checkCancellation()
      diagnostics.append("Login PATH: \(error.localizedDescription)")
    }
    if let loginPath, !loginPath.isEmpty,
      let executable = try await firstWorking(
        in: loginPath, shell: shell, tried: &tried, diagnostics: &diagnostics)
    {
      return executable
    }
    let fallback = (fallbackPaths + [processPath]).joined(separator: ":")
    if let executable = try await firstWorking(
      in: fallback, shell: shell, tried: &tried, diagnostics: &diagnostics)
    {
      return executable
    }
    throw GitClientError.unavailable(details: diagnostics.joined(separator: "\n"))
  }

  private func firstWorking(
    in path: String, shell: ShellClient, tried: inout Set<String>, diagnostics: inout [String]
  ) async throws -> GitExecutable? {
    try Task.checkCancellation()
    for directory in path.split(separator: ":") where directory.hasPrefix("/") {
      try Task.checkCancellation()
      let url = URL(fileURLWithPath: String(directory)).appending(path: "git")
      // The same executable can need a different PATH for its helper programs.
      guard tried.insert("\(url.path)|\(path)").inserted,
        FileManager.default.isExecutableFile(atPath: url.path)
      else { continue }
      let searchPath = "\(directory):\(path)"
      let executable = GitExecutable(url: url, searchPath: searchPath)
      if try await validate(executable, shell: shell, diagnostics: &diagnostics) {
        return executable
      }
    }
    return nil
  }

  private func validate(
    _ executable: GitExecutable, shell: ShellClient, diagnostics: inout [String]
  ) async throws -> Bool {
    do {
      try Task.checkCancellation()
      let output = try await executable.run(["--version"], shell: shell)
      try Task.checkCancellation()
      guard output.stdout.hasPrefix("git version ") else {
        diagnostics.append("\(executable.url.path): unexpected version output")
        return false
      }
      return true
    } catch {
      try Task.checkCancellation()
      diagnostics.append("\(executable.url.path): \(error.localizedDescription)")
      return false
    }
  }
}
