import Sparkle
import Testing

@testable import supacode

struct UpdaterClientTests {
  @Test func backgroundUpdateDoesNotPreserveInstallingState() {
    #expect(silentBackgroundUpdateChoice(for: .notDownloaded) == .dismiss)
    #expect(silentBackgroundUpdateChoice(for: .downloaded) == .dismiss)
    #expect(silentBackgroundUpdateChoice(for: .installing) == .skip)
  }

  @Test func installAndRelaunchRequiresConfirmation() {
    #expect(installAndRelaunchChoice(didConfirm: true) == .install)
    #expect(installAndRelaunchChoice(didConfirm: false) == .skip)
  }

  @Test func userInitiatedInstallingUpdateRequiresImmediateConfirmation() {
    #expect(!shouldConfirmInstallAndRelaunchImmediately(for: .notDownloaded))
    #expect(!shouldConfirmInstallAndRelaunchImmediately(for: .downloaded))
    #expect(shouldConfirmInstallAndRelaunchImmediately(for: .installing))
  }
}
