import Foundation
import Testing

@testable import Prowl

struct GitAutomaticBaseRefTests {
  @Test func failedDefaultBranchProbeKeepsDiagnosticsPrivate() async throws {
    let client = GitClient(shell: .live, resolveGit: { _ in throw PrivateResolverError() })

    let ref = try await client.defaultRemoteBranchRef(for: URL(filePath: "/private-repository"))
    #expect(ref == nil)
  }

  @Test func prefersRemoteWhenAvailable() {
    let value = GitClient.preferredBaseRef(remote: "origin/main", localHead: "main")
    #expect(value == "origin/main")
  }

  @Test func fallsBackToLocalHead() {
    let value = GitClient.preferredBaseRef(remote: nil, localHead: "main")
    #expect(value == "main")
  }

  @Test func returnsNilWhenNoRefs() {
    let value = GitClient.preferredBaseRef(remote: nil, localHead: nil)
    #expect(value == nil)
  }
}

private struct PrivateResolverError: LocalizedError {
  nonisolated var errorDescription: String? {
    Issue.record("The fallback requested private diagnostics from a discarded error")
    return "private resolver details"
  }
}
