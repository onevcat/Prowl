import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CLIProfilesCommandHandlerTests {
  @Test func listPreservesOrderAndMapsShellProbeAvailability() async throws {
    let available = AgentProfile(name: "Reviewer", runtime: .claude)
    let unavailable = AgentProfile(name: "Builder", isEnabled: false, runtime: .codex)
    let unknown = AgentProfile(name: "Researcher", runtime: .amp)
    let checkedAt = Date(timeIntervalSince1970: 1_787_390_000)
    let handler = ProfilesCommandHandler {
      ProfilesRuntimeSnapshot(
        profiles: [available, unavailable, unknown],
        probeResults: [
          .claude: AgentRuntimeAvailabilityProbeResult(isAvailable: true, checkedAt: checkedAt),
          .codex: AgentRuntimeAvailabilityProbeResult(isAvailable: false, checkedAt: checkedAt),
        ]
      )
    }

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .profiles(ProfilesInput()))
    )

    #expect(response.ok)
    #expect(response.schemaVersion == "prowl.cli.profiles.v1")
    let data = try #require(response.data)
    let payload = try data.decode(as: ProfilesCommandPayload.self)
    #expect(payload.count == 3)
    #expect(payload.profiles.map(\.id) == [available.id, unavailable.id, unknown.id].map(\.uuidString))
    #expect(payload.profiles.map(\.enabled) == [true, false, true])
    #expect(payload.profiles.map(\.runtime) == ["claude", "codex", "amp"])
    #expect(payload.profiles[0].availability == ProfilesCommandAvailability(status: .available))
    #expect(
      payload.profiles[1].availability
        == ProfilesCommandAvailability(
          status: .unavailable,
          reason: "Codex is not on your shell's PATH"
        )
    )
    #expect(
      payload.profiles[2].availability
        == ProfilesCommandAvailability(
          status: .unknown,
          reason: "Availability check has not completed"
        )
    )
  }

  @Test func snapshotFailureReturnsProfilesFailed() async {
    struct SnapshotError: Error {}
    let handler = ProfilesCommandHandler { throw SnapshotError() }

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .profiles(ProfilesInput()))
    )

    #expect(!response.ok)
    #expect(response.schemaVersion == "prowl.cli.profiles.v1")
    #expect(response.error?.code == CLIErrorCode.profilesFailed)
  }
}
