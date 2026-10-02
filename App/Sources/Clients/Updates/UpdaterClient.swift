import AppKit
import ComposableArchitecture
import Sparkle

private let updaterLogger = SupaLogger("Updater")

struct UpdaterClient {
  var configure: @MainActor @Sendable (_ checks: Bool, _ checkInBackground: Bool) -> Void
  var checkForUpdates: @MainActor @Sendable () -> Void
  var installDownloadedUpdate: @MainActor @Sendable () -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>
}

extension UpdaterClient {
  enum Event: Equatable, Sendable {
    case silentUpdateFound(version: String?)
    case downloadedUpdateReadyToInstall(version: String?)
  }
}

@MainActor
final class SparkleUpdateDelegate: NSObject, SPUUpdaterDelegate {
  private var continuation: AsyncStream<UpdaterClient.Event>.Continuation?
  private var immediateInstallHandler: (() -> Void)?

  func setContinuation(_ continuation: AsyncStream<UpdaterClient.Event>.Continuation) {
    self.continuation?.finish()
    self.continuation = continuation
  }

  func installDownloadedUpdate() {
    immediateInstallHandler?()
  }

  func updater(
    _ updater: SPUUpdater,
    willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    self.immediateInstallHandler = immediateInstallHandler
    continuation?.yield(.downloadedUpdateReadyToInstall(version: item.displayVersionString))
    return true
  }
}

/// Custom Sparkle user driver that turns background "update found" prompts into a silent signal,
/// while forwarding user-initiated flows to the standard Sparkle UI.
@MainActor
final class SilentUpdateDriver: NSObject, SPUUserDriver {
  private let standard: SPUStandardUserDriver
  private var continuation: AsyncStream<UpdaterClient.Event>.Continuation?
  private var automaticallyChecksForUpdates = GlobalSettings.default.updatesAutomaticallyCheckForUpdates

  init(hostBundle: Bundle) {
    self.standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
    super.init()
  }

  func setAutomaticUpdatePreferences(checks: Bool) {
    automaticallyChecksForUpdates = checks
  }

  func setContinuation(_ continuation: AsyncStream<UpdaterClient.Event>.Continuation) {
    self.continuation?.finish()
    self.continuation = continuation
  }

  // `SPUUserDriver` is declared `NS_SWIFT_UI_ACTOR` (main-actor isolated) as of Sparkle 2.9,
  // so these callbacks are guaranteed to arrive on the main thread. Implement them as plain
  // `@MainActor` methods and let the compiler enforce isolation, rather than reaching for
  // `MainActor.assumeIsolated`, which would crash on any future off-main delivery.
  func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void
  ) {
    reply(
      SUUpdatePermissionResponse(
        automaticUpdateChecks: automaticallyChecksForUpdates,
        automaticUpdateDownloading: nil,
        sendSystemProfile: false
      )
    )
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping @Sendable () -> Void) {
    standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
  }

  func showUpdateFound(
    with appcastItem: SUAppcastItem,
    state: SPUUserUpdateState,
    reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
  ) {
    if state.userInitiated {
      if shouldConfirmInstallAndRelaunchImmediately(for: state.stage) {
        reply(confirmInstallAndRelaunchChoice())
        return
      }
      standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
      return
    }
    // Background check: surface the availability silently, then defer so Sparkle
    // will re-offer the same update on the next (user-initiated) check.
    continuation?.yield(.silentUpdateFound(version: appcastItem.displayVersionString))
    reply(silentBackgroundUpdateChoice(for: state.stage))
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    standard.showUpdateReleaseNotes(with: downloadData)
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
    standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
  }

  func showUpdateNotFoundWithError(
    _ error: any Error,
    acknowledgement: @escaping @Sendable () -> Void
  ) {
    standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
  }

  func showUpdaterError(
    _ error: any Error,
    acknowledgement: @escaping @Sendable () -> Void
  ) {
    standard.showUpdaterError(error, acknowledgement: acknowledgement)
  }

  func showDownloadInitiated(cancellation: @escaping @Sendable () -> Void) {
    standard.showDownloadInitiated(cancellation: cancellation)
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    standard.showDownloadDidReceiveData(ofLength: length)
  }

  func showDownloadDidStartExtractingUpdate() {
    standard.showDownloadDidStartExtractingUpdate()
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    standard.showExtractionReceivedProgress(progress)
  }

  func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
    reply(confirmInstallAndRelaunchChoice())
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping @Sendable () -> Void
  ) {
    standard.showInstallingUpdate(
      withApplicationTerminated: applicationTerminated,
      retryTerminatingApplication: retryTerminatingApplication
    )
  }

  func showUpdateInstalledAndRelaunched(
    _ relaunched: Bool,
    acknowledgement: @escaping @Sendable () -> Void
  ) {
    standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
  }

  func showUpdateInFocus() {
    standard.showUpdateInFocus()
  }

  func dismissUpdateInstallation() {
    standard.dismissUpdateInstallation()
  }
}

func silentBackgroundUpdateChoice(for stage: SPUUserUpdateStage) -> SPUUserUpdateChoice {
  switch stage {
  case .notDownloaded, .downloaded:
    .dismiss
  case .installing:
    .skip
  @unknown default:
    .dismiss
  }
}

func installAndRelaunchChoice(didConfirm: Bool) -> SPUUserUpdateChoice {
  didConfirm ? .install : .skip
}

func shouldConfirmInstallAndRelaunchImmediately(for stage: SPUUserUpdateStage) -> Bool {
  stage == .installing
}

@MainActor
private func confirmInstallAndRelaunchChoice() -> SPUUserUpdateChoice {
  let alert = NSAlert()
  alert.messageText = String(localized: "Install Update and Relaunch?")
  alert.informativeText = String(
    localized: "Prowl will quit and relaunch to finish installing the update."
  )
  alert.addButton(withTitle: String(localized: "Install and Relaunch"))
  alert.addButton(withTitle: String(localized: "Later"))
  return installAndRelaunchChoice(didConfirm: alert.runModal() == .alertFirstButtonReturn)
}

extension UpdaterClient: DependencyKey {
  static let liveValue: UpdaterClient = {
    let hostBundle = Bundle.main
    let delegate = SparkleUpdateDelegate()
    let driver = SilentUpdateDriver(hostBundle: hostBundle)
    let updater = SPUUpdater(
      hostBundle: hostBundle,
      applicationBundle: hostBundle,
      userDriver: driver,
      delegate: delegate
    )
    do {
      try updater.start()
    } catch {
      updaterLogger.warning("SPUUpdater start failed: \(String(describing: error))")
    }
    return UpdaterClient(
      configure: { checks, checkInBackground in
        driver.setAutomaticUpdatePreferences(checks: checks)
        updater.updateCheckInterval = 3600
        updater.automaticallyChecksForUpdates = checks
        if checkInBackground, checks {
          updater.checkForUpdatesInBackground()
        }
      },
      checkForUpdates: {
        updater.checkForUpdates()
      },
      installDownloadedUpdate: {
        delegate.installDownloadedUpdate()
      },
      events: {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        driver.setContinuation(continuation)
        delegate.setContinuation(continuation)
        return stream
      }
    )
  }()

  static let testValue = UpdaterClient(
    configure: { _, _ in },
    checkForUpdates: {},
    installDownloadedUpdate: {},
    events: { AsyncStream { _ in } }
  )
}

extension DependencyValues {
  var updaterClient: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}
