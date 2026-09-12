import Foundation
import Testing
@testable import ProwlMirror_iOS

@MainActor
struct MirrorLaunchModelTests {
  @Test func deduplicatesWorktreesAndUsesOnlyAvailableHostProfiles() async {
    let model = MirrorLaunchModel { command in
      switch command {
      case .agentsDispatch, .send: throw CancellationError()
      case .list: return try json(Self.listing)
      case .profiles: return try json(Self.profiles)
      case .create: throw CancellationError()
      }
    }
    await model.load()
    #expect(model.worktrees.count == 1)
    #expect(model.worktreeID == "worktree-1")
    #expect(model.profileID == "available-profile")
    #expect(model.canCreate)
    model.profileID = "disabled-profile"
    #expect(!model.canCreate)
  }

  @Test func launchPreservesMultilinePromptAndUsesOrdinaryBackgroundTab() async throws {
    var requests: [MirrorCommandRequest.Create] = []
    let model = MirrorLaunchModel { command in
      switch command {
      case .agentsDispatch, .send: throw CancellationError()
      case .list: return try json(Self.listing)
      case .profiles: return try json(Self.profiles)
      case .create(let create): requests.append(create); return try json(Self.created)
      }
    }
    await model.load()
    model.prompt = "first\nsecond"
    let pane = try #require(await model.create())
    #expect(pane.title == "Codex")
    #expect(pane.projectName == "Project")
    #expect(requests.count == 1)
    #expect(requests[0].background && requests[0].resource == "tab")
    #expect(requests[0].launch.prompt == "first\nsecond")
    #expect(requests[0].launch.profile == "available-profile")
  }

  @Test func lostCreationResponseIsNeverAutomaticallyReplayed() async {
    var calls = 0
    let model = MirrorLaunchModel { command in
      switch command {
      case .agentsDispatch, .send: throw CancellationError()
      case .list: return try json(Self.listing)
      case .profiles: return try json(Self.profiles)
      case .create: calls += 1; throw URLError(.networkConnectionLost)
      }
    }
    await model.load()
    #expect(await model.create() == nil)
    #expect(model.creationUncertain)
    #expect(!model.canCreate)
    await model.load()
    #expect(await model.create() == nil)
    #expect(calls == 1)
  }

  @Test func unconfirmedHostResultBlocksAnotherCreation() async {
    let model = MirrorLaunchModel { command in
      switch command {
      case .agentsDispatch, .send: throw CancellationError()
      case .list: return try json(Self.listing)
      case .profiles: return try json(Self.profiles)
      case .create:
        return try json(#"{"ok":false,"error":{"code":"REMOTE_COMMAND_UNCONFIRMED","message":"Encoding failed"}}"#)
      }
    }
    await model.load()
    #expect(await model.create() == nil)
    #expect(model.creationUncertain)
    #expect(!model.canCreate)
  }

  @Test func explicitRejectionKeepsTheFormEditable() async {
    let model = MirrorLaunchModel { command in
      switch command {
      case .agentsDispatch, .send: throw CancellationError()
      case .list: return try json(Self.listing)
      case .profiles: return try json(Self.profiles)
      case .create: return try json(#"{"ok":false,"error":{"message":"Profile removed"}}"#)
      }
    }
    await model.load()
    #expect(await model.create() == nil)
    #expect(model.error == "Profile removed")
    #expect(!model.creationUncertain)
    #expect(model.canCreate)
  }

  @Test func emptyCatalogAndOversizedPromptCannotLaunch() async {
    let empty = MirrorLaunchModel { _ in try json(#"{"ok":true,"data":{"items":[],"profiles":[]}}"#) }
    await empty.load()
    #expect(!empty.canCreate)
    let model = MirrorLaunchModel { command in
      if case .profiles = command { return try json(Self.profiles) }
      return try json(Self.listing)
    }
    await model.load()
    model.prompt = String(repeating: "你", count: MirrorWire.maximumInput / 3 + 1)
    #expect(!model.canCreate)
  }

  private static let listing = #"{"ok":true,"data":{"items":[{"worktree":{"id":"worktree-1","name":"main","path":"/Project","root_path":"/Project"}},{"worktree":{"id":"worktree-1","name":"main","path":"/Project","root_path":"/Project"}}]}}"#
  private static let profiles = #"{"ok":true,"data":{"profiles":[{"id":"disabled-profile","name":"Disabled","enabled":false,"runtime":"claude","availability":{"status":"available"}},{"id":"available-profile","name":"Codex","enabled":true,"runtime":"codex","availability":{"status":"available"}}]}}"#
  private static let created = #"{"ok":true,"data":{"target":{"worktree":{"id":"worktree-1","name":"main","path":"/Project","root_path":"/Project"},"pane":{"id":"03F5535A-D08C-498C-B70B-C665AC8D02CB","title":"Codex"}}}}"#
}

private func json(_ string: String) throws -> MirrorJSON {
  try JSONDecoder().decode(MirrorJSON.self, from: Data(string.utf8))
}
