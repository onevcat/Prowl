import Foundation
import Testing

@testable import Prowl

/// The side channel against a real host (docs-ai 082). Disabled unless
/// `PROWL_TEST_SSH_HOST` names a destination that `ssh -o BatchMode=yes` reaches;
/// `PROWL_TEST_SSH_OPTIONS` adds space-separated options (for example `-p 2222`).
/// Run with `TEST_RUNNER_PROWL_TEST_SSH_HOST=<host> xcodebuild test …`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROWL_TEST_SSH_HOST"] != nil))
struct RemoteConnectionLiveTests {
  private var recipe: SSHConnectionRecipe {
    let environment = ProcessInfo.processInfo.environment
    let options = environment["PROWL_TEST_SSH_OPTIONS"]?.split(separator: " ").map(String.init) ?? []
    return SSHConnectionRecipe(destination: environment["PROWL_TEST_SSH_HOST"] ?? "", options: options)
  }

  @Test func probeOverTheSideChannelReturnsACompleteReport() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "prowl-ssh-live", directoryHint: .isDirectory)
    let registry = RemoteConnectionRegistry(
      configuration: RemoteConnectionOwner.Configuration(controlDirectory: directory.path(percentEncoded: false)))
    let key = try #require(await registry.resolve(recipe))
    let owner = await registry.owner(for: key, recipe: recipe)
    let (id, _) = await owner.subscribe()
    await owner.requestRefresh()
    await owner.waitUntilIdle()
    let first = try #require(await owner.latest)
    #expect(first.outcome == .complete, "\(first.outcome)")
    #expect(first.report.map { !$0.bootID.isEmpty } == true)
    // The second run reuses the master.
    await owner.requestRefresh()
    await owner.waitUntilIdle()
    let second = try #require(await owner.latest)
    #expect(second.outcome == .complete)
    #expect(second.sequence == first.sequence + 1)
    #expect(second.report?.bootID == first.report?.bootID)
    await owner.unsubscribe(id)
    await registry.releaseIfUnused(key)
    #expect(!FileManager.default.fileExists(atPath: await owner.controlPath))
  }
}
