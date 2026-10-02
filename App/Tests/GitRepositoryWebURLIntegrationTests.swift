import Foundation
import Testing

@testable import supacode

struct GitRepositoryWebURLIntegrationTests {
  @Test func returnsNilWhenRepositoryHasNoRemote() async throws {
    let repoURL = try makeTemporaryRepo(namePrefix: "supacode-weburl-no-remote")
    defer { try? FileManager.default.removeItem(at: repoURL) }

    let url = await GitClient().repositoryWebURL(for: repoURL)

    #expect(url == nil)
  }

  @Test func returnsNilWhenRemoteCannotBeParsed() async throws {
    let repoURL = try makeTemporaryRepo(namePrefix: "supacode-weburl-unparseable")
    defer { try? FileManager.default.removeItem(at: repoURL) }

    try runGit([
      "-C", repoURL.path(percentEncoded: false),
      "remote", "add", "origin", "/tmp/local-only/repo.git",
    ])

    let url = await GitClient().repositoryWebURL(for: repoURL)

    #expect(url == nil)
  }

  @Test func preservesCustomPortAndPathPrefixFromRemote() async throws {
    let repoURL = try makeTemporaryRepo(namePrefix: "supacode-weburl-port-prefix")
    defer { try? FileManager.default.removeItem(at: repoURL) }

    try runGit([
      "-C", repoURL.path(percentEncoded: false),
      "remote", "add", "origin", "ssh://git@git.example.com:8443/scm/platform/repo.git",
    ])

    let url = await GitClient().repositoryWebURL(for: repoURL)

    #expect(url == URL(string: "https://git.example.com:8443/scm/platform/repo"))
  }
}

private struct GitCommandError: Error {
  let output: String
}

private func makeTemporaryRepo(namePrefix: String) throws -> URL {
  let tempRoot = URL(filePath: "/tmp", directoryHint: .isDirectory)
  let repoURL = tempRoot.appending(
    path: "\(namePrefix)-\(UUID().uuidString)",
    directoryHint: URL.DirectoryHint.isDirectory
  )
  try runGit(["init", repoURL.path(percentEncoded: false)])
  return repoURL
}

@discardableResult
private func runGit(_ arguments: [String]) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = arguments
  var environment = ProcessInfo.processInfo.environment
  environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
  process.environment = environment
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  process.waitUntilExit()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  let output = String(data: data, encoding: .utf8) ?? ""
  if process.terminationStatus != 0 {
    throw GitCommandError(output: output)
  }
  return output
}
