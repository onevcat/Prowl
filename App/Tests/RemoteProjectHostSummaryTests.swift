import Foundation
import Testing

@testable import Prowl

/// What the sidebar tells about the host of a remote project.
struct RemoteProjectHostSummaryTests {
  private static let profile = HostProfile(
    id: UUID(), alias: "mini", recipe: SSHConnectionRecipe(destination: "mini"),
    connectionKey: ConnectionKey(user: "dev", hostname: "192.168.1.20"))

  @Test func aRemoteProjectNamesItsHostTargetAndPath() throws {
    let location = RepositoryLocation.remote(hostProfileID: Self.profile.id, path: "/home/dev/app")
    let summary = try #require(RemoteProjectHostSummary(location: location, hostProfiles: [Self.profile]))

    #expect(summary.title == "Remote project on mini")
    #expect(
      summary.details == """
        Remote project on mini
        Host: dev@192.168.1.20
        Path: /home/dev/app
        """)
  }

  /// Another port and a jump host are part of the target, so they are shown too.
  @Test func anotherPortAndJumpHostsAreShown() throws {
    var profile = Self.profile
    profile.connectionKey = ConnectionKey(
      user: "dev", hostname: "build.internal", port: 2222, jumpChain: ["bastion", "gate"])
    let location = RepositoryLocation.remote(hostProfileID: profile.id, path: "/srv/app")
    let summary = try #require(RemoteProjectHostSummary(location: location, hostProfiles: [profile]))

    #expect(
      summary.details == """
        Remote project on mini
        Host: dev@build.internal:2222
        Through: bastion → gate
        Path: /srv/app
        """)
  }

  /// A local project has no summary; a remote one whose host is gone still says it is remote.
  @Test func aLocalProjectHasNoSummaryAndAMissingHostIsNamed() throws {
    let local = RepositoryLocation.local(URL(fileURLWithPath: "/tmp/app"))
    #expect(RemoteProjectHostSummary(location: local, hostProfiles: [Self.profile]) == nil)

    let orphan = RepositoryLocation.remote(hostProfileID: UUID(), path: "/srv/app")
    let summary = try #require(RemoteProjectHostSummary(location: orphan, hostProfiles: [Self.profile]))
    #expect(
      summary.details == """
        Remote project on an unknown host
        Path: /srv/app
        """)
  }
}
