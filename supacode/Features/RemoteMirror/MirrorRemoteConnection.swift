import Foundation
import Network

@MainActor
protocol MirrorTransport: AnyObject {
  var onReady: (() -> Void)? { get set }
  var onMessage: ((MirrorMessage) -> Void)? { get set }
  var onClose: ((String?) -> Void)? { get set }
  var verifiedConfiguration: MirrorSavedConnection? { get }
  func start()
  func send(_ message: MirrorMessage, closeAfterSending: Bool)
  func close(_ reason: String?)
}

extension MirrorTransport {
  var verifiedConfiguration: MirrorSavedConnection? { nil }
  func send(_ message: MirrorMessage) { send(message, closeAfterSending: false) }
  func close() { close(nil) }
}
extension MirrorConnection: MirrorTransport {}

/// Authentication completes before discovery callbacks are exposed to the UI.
@MainActor
final class MirrorRemoteConnection: MirrorTransport {
  var onReady: (() -> Void)?
  var onMessage: ((MirrorMessage) -> Void)?
  var onClose: ((String?) -> Void)?
  private(set) var verifiedConfiguration: MirrorSavedConnection?
  private var configuration: MirrorSavedConnection
  private var connection: MirrorConnection?
  private var challenge: MirrorMessage.Challenge?
  private var closed = false
  private var authenticated = false

  private let restore: (MirrorSavedConnection) throws -> MirrorSavedConnection?
  private let persist: (MirrorSavedConnection) throws -> Void

  init(
    configuration: MirrorSavedConnection,
    restore: @escaping (MirrorSavedConnection) throws -> MirrorSavedConnection? = {
      try MirrorSavedConnection.load(account: "host:" + $0.address + ":" + String($0.port))
    },
    persist: @escaping (MirrorSavedConnection) throws -> Void = {
      try $0.save(account: "host:" + $0.address + ":" + String($0.port))
      try $0.save()
    }
  ) {
    self.configuration = configuration
    self.restore = restore
    self.persist = persist
  }

  func start() {
    guard connection == nil, !closed else { return }
    do {
      guard configuration.port > 0 else { throw MirrorProtocolError.invalidMessage }
      if configuration.credential == nil, configuration.pairingKey.isEmpty,
        let saved = try restore(configuration)
      {
        configuration.credential = saved.credential
      }
      let parameters: NWParameters
      if let credential = configuration.credential {
        guard credential.key.count == 32 else { throw MirrorProtocolError.invalidMessage }
        parameters = try MirrorConnection.parameters(keys: [
          (credential.deviceID.uuidString, credential.key)
        ])
      } else {
        parameters = try MirrorConnection.parameters(pairingKey: configuration.pairingKey)
      }
      let peer = MirrorConnection(
        NWConnection(
          host: .init(configuration.address),
          port: .init(rawValue: configuration.port)!, using: parameters))
      connection = peer
      peer.onMessage = { [weak self] in self?.receive($0) }
      peer.onClose = { [weak self] reason in
        guard let self, !self.closed else { return }
        self.closed = true
        self.onClose?(reason)
      }
      peer.start()
    } catch { close(error.localizedDescription) }
  }

  func send(_ message: MirrorMessage, closeAfterSending: Bool = false) {
    guard authenticated, !closed else { return }
    connection?.send(message, closeAfterSending: closeAfterSending)
  }

  func close(_ reason: String? = nil) {
    guard !closed else { return }
    closed = true
    connection?.onClose = nil
    connection?.close(reason)
    connection = nil
    onClose?(reason)
  }

  private func receive(_ message: MirrorMessage) {
    if authenticated {
      onMessage?(message)
      return
    }
    do {
      switch message {
      case .challenge(let value):
        guard challenge == nil, value.nonce.count == 32 else {
          throw MirrorProtocolError.invalidMessage
        }
        challenge = value
        if let credential = configuration.credential {
          guard credential.hostID == value.hostID else {
            close("Host identity changed. Pair with this Host again.")
            return
          }
          connection?.send(
            .authenticate(
              .init(
                deviceID: credential.deviceID,
                proof: MirrorAuthentication.proof(
                  key: credential.key, host: value.hostID,
                  nonce: value.nonce, purpose: "device", identity: credential.deviceID.uuidString)))
          )
        } else {
          let code = try MirrorPairingCode.normalized(configuration.pairingKey)
          let name = String(ProcessInfo.processInfo.hostName.prefix(80))
          connection?.send(
            .pair(
              .init(
                name: name,
                proof: MirrorAuthentication.proof(
                  key: Data(code.utf8), host: value.hostID,
                  nonce: value.nonce, purpose: "pair", identity: name))))
        }
      case .paired(let credential):
        guard configuration.credential == nil, credential.hostID == challenge?.hostID,
          credential.key.count == 32
        else { throw MirrorProtocolError.invalidMessage }
        configuration.credential = credential
        configuration.pairingKey = ""
        // Save before reconnect: a successful pairing response must never depend on UI lifetime.
        try persist(configuration)
        connection?.onClose = nil
        connection?.close()
        connection = nil
        challenge = nil
        start()
      case .authenticated(let hostID):
        guard let credential = configuration.credential, credential.hostID == hostID,
          challenge?.hostID == hostID
        else { throw MirrorProtocolError.invalidMessage }
        try persist(configuration)
        verifiedConfiguration = configuration
        authenticated = true
        onReady?()
      case .failure(let failure): close(failure.error)
      default: throw MirrorProtocolError.invalidMessage
      }
    } catch { close(error.localizedDescription) }
  }

}
