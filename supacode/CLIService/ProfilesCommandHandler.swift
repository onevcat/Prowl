import Foundation
import ProwlCLIShared

struct ProfilesRuntimeSnapshot {
  let profiles: [AgentProfile]
  let probeResults: [AgentProfileRuntime: AgentRuntimeAvailabilityProbeResult]
}

final class ProfilesCommandHandler: CommandHandler {
  typealias SnapshotProvider = @MainActor () throws -> ProfilesRuntimeSnapshot

  private let snapshotProvider: SnapshotProvider

  init(snapshotProvider: @escaping SnapshotProvider) {
    self.snapshotProvider = snapshotProvider
  }

  // swiftlint:disable:next async_without_await
  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    do {
      let snapshot = try snapshotProvider()
      let payload = ProfilesCommandPayload(
        count: snapshot.profiles.count,
        profiles: snapshot.profiles.map { profile in
          ProfilesCommandProfile(
            id: profile.id.uuidString,
            name: profile.name,
            enabled: profile.isEnabled,
            runtime: profile.runtime.rawValue,
            availability: availability(
              for: profile.runtime,
              probeResult: snapshot.probeResults[profile.runtime]
            )
          )
        }
      )
      return try CommandResponse(
        ok: true,
        command: "profiles",
        schemaVersion: "prowl.cli.profiles.v1",
        data: RawJSON(encoding: payload)
      )
    } catch {
      return CommandResponse(
        ok: false,
        command: "profiles",
        schemaVersion: "prowl.cli.profiles.v1",
        error: CommandError(
          code: CLIErrorCode.profilesFailed,
          message: "Failed to list Agent Profiles."
        )
      )
    }
  }

  private func availability(
    for runtime: AgentProfileRuntime,
    probeResult: AgentRuntimeAvailabilityProbeResult?
  ) -> ProfilesCommandAvailability {
    guard let probeResult else {
      return ProfilesCommandAvailability(
        status: .unknown,
        reason: "Availability check has not completed"
      )
    }
    if probeResult.isAvailable {
      return ProfilesCommandAvailability(status: .available)
    }
    let name = AgentRuntimeAdapterRegistry.displayName(for: runtime)
    return ProfilesCommandAvailability(
      status: .unavailable,
      reason: "\(name) is not on your shell's PATH"
    )
  }
}
