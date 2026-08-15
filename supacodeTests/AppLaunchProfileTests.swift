import Foundation
import Testing

@testable import supacode

struct AppLaunchProfileTests {
  @Test(
    arguments: [
      (DefaultViewMode.normal, AppLaunchProfile.standard(initialViewMode: .normal)),
      (DefaultViewMode.shelf, AppLaunchProfile.standard(initialViewMode: .shelf)),
      (DefaultViewMode.canvas, AppLaunchProfile.standard(initialViewMode: .canvas)),
      (DefaultViewMode.clean, AppLaunchProfile.clean),
    ]
  )
  func resolvesStoredViewMode(
    mode: DefaultViewMode,
    expectedProfile: AppLaunchProfile
  ) {
    #expect(AppLaunchProfile.resolve(mode) == expectedProfile)
  }

  @Test func cleanModeCodableRoundTrips() throws {
    let encoded = try JSONEncoder().encode(DefaultViewMode.clean)
    let decoded = try JSONDecoder().decode(DefaultViewMode.self, from: encoded)

    #expect(String(decoding: encoded, as: UTF8.self) == #""clean""#)
    #expect(decoded == .clean)
  }
}
