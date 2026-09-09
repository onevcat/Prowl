import Foundation
import Network
import Security

@MainActor
final class MirrorConnection {
  let id = UUID()
  let connection: NWConnection
  var onMessage: ((MirrorMessage) -> Void)?
  var onReady: (() -> Void)?
  var onClose: ((String?) -> Void)?
  private var closed = false
  private var queuedBytes = 0
  private var heartbeat: Task<Void, Never>?
  private var deadline: Task<Void, Never>?
  private let clock: any Clock<Duration>
  private var becameReady = false

  init(_ connection: NWConnection, clock: any Clock<Duration> = ContinuousClock()) {
    self.connection = connection
    self.clock = clock
  }

  static func parameters(pairingKey: String) throws -> NWParameters {
    let key = pairingKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard key.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw MirrorProtocolError.invalidPairingKey
    }
    let tls = NWProtocolTLS.Options()
    let secret = Data(key.utf8)
    let identity = Data("prowl-remote-mirror-v1".utf8)
    secret.withUnsafeBytes { keyBytes in
      identity.withUnsafeBytes { identityBytes in
        sec_protocol_options_add_pre_shared_key(
          tls.securityProtocolOptions,
          DispatchData(bytes: keyBytes) as __DispatchData,
          DispatchData(bytes: identityBytes) as __DispatchData)
      }
    }
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    // Security's Swift enum omits the PSK suites supported by Network.framework.
    guard let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) else {
      throw MirrorProtocolError.invalidMessage
    }
    sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, suite)
    let tcp = NWProtocolTCP.Options()
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 15
    let parameters = NWParameters(tls: tls, tcp: tcp)
    return parameters
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self, !self.closed else { return }
        switch state {
        case .ready:
          self.becameReady = true
          self.resetDeadline()
          self.onReady?()
          self.readHeader()
          let clock = self.clock
          self.heartbeat = Task { [weak self] in
            while !Task.isCancelled {
              do { try await clock.sleep(for: .seconds(2)) } catch { return }
              self?.send(MirrorMessage(kind: .ping))
            }
          }
        case .failed(let error): self.close(error.localizedDescription)
        case .cancelled: self.close(nil)
        case .waiting(let error):
          if self.becameReady { self.close("Connection lost: \(error.localizedDescription)") }
        default: break
        }
      }
    }
    resetDeadline()
    connection.start(queue: .main)
  }

  func send(_ message: MirrorMessage) {
    guard !closed else { return }
    do {
      let bytes = try MirrorWire.encode(message)
      guard queuedBytes + bytes.count <= 2 * MirrorWire.maximumPayload else {
        close("Remote receiver is too slow.")
        return
      }
      queuedBytes += bytes.count
      connection.send(
        content: bytes,
        completion: .contentProcessed { [weak self] error in
          Task { @MainActor in
            guard let self, !self.closed else { return }
            self.queuedBytes -= bytes.count
            if let error { self.close(error.localizedDescription) }
          }
        })
    } catch { close(error.localizedDescription) }
  }

  func close(_ reason: String? = nil) {
    guard !closed else { return }
    closed = true
    deadline?.cancel()
    heartbeat?.cancel()
    connection.stateUpdateHandler = nil
    connection.cancel()
    let callback = onClose
    onMessage = nil
    onReady = nil
    onClose = nil
    callback?(reason)
  }

  private func resetDeadline() {
    deadline?.cancel()
    let clock = clock
    let timeout: Duration = becameReady ? .seconds(8) : .seconds(30)
    deadline = Task { [weak self] in
      do { try await clock.sleep(for: timeout) } catch { return }
      self?.close("Remote connection timed out. The other side is no longer responding.")
    }
  }

  private func readHeader() {
    read(count: 4) { [weak self] header in
      guard let self else { return }
      do {
        let length = try MirrorWire.length(header)
        self.read(count: length) { [weak self] payload in
          guard let self else { return }
          do {
            let message = try MirrorWire.decode(payload)
            self.resetDeadline()
            if message.kind == .ping {
              self.send(MirrorMessage(kind: .pong))
            } else if message.kind != .pong {
              self.onMessage?(message)
            }
            if !self.closed { self.readHeader() }
          } catch { self.close(error.localizedDescription) }
        }
      } catch { self.close(error.localizedDescription) }
    }
  }

  private func read(count: Int, completion: @escaping @MainActor (Data) -> Void) {
    connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, done, error in
      Task { @MainActor in
        guard let self, !self.closed else { return }
        guard let data, data.count == count, error == nil else {
          self.close(error?.localizedDescription ?? (done ? "Host disconnected." : "Incomplete remote message."))
          return
        }
        completion(data)
      }
    }
  }
}
