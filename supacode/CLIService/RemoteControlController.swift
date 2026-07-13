@MainActor
final class RemoteControlController {
  private let server: RemoteControlServer
  private let accessTokenStore: RemoteControlAccessTokenStore
  private let logger = SupaLogger("RemoteControl")

  init(server: RemoteControlServer, accessTokenStore: RemoteControlAccessTokenStore = .shared) {
    self.server = server
    self.accessTokenStore = accessTokenStore
  }

  func setEnabled(_ enabled: Bool) -> Bool {
    if !enabled {
      server.stop()
      logger.info("Remote control bridge stopped")
      return true
    }
    guard !server.isRunning else { return true }
    do {
      _ = try accessTokenStore.loadOrCreate()
      try server.start()
      logger.info("Remote control bridge started on loopback")
      return true
    } catch {
      logger.warning("Unable to start remote control bridge")
      return false
    }
  }

  func stop() {
    server.stop()
  }
}
