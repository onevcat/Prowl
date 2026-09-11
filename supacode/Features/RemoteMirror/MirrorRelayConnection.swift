import Foundation
import Network

@MainActor
final class MirrorRelayConnection {
  var onPacket: ((MirrorRelayPacket) -> Void)?
  var onClose: ((String?) -> Void)?
  private let connection: NWConnection
  private var closed = false
  private var queuedBytes = 0

  init(_ connection: NWConnection) { self.connection = connection }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self, !self.closed else { return }
        switch state {
        case .ready: self.readHeader()
        case .failed(let error): self.close(error.localizedDescription)
        case .cancelled: self.close()
        default: break
        }
      }
    }
    connection.start(queue: .main)
  }

  func send(_ packet: MirrorRelayPacket) {
    guard !closed else { return }
    do {
      let bytes = try packet.encoded()
      guard queuedBytes + bytes.count <= 2 * MirrorRelayPacket.maximumPayload else {
        close("Display relay is too slow.")
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
    connection.stateUpdateHandler = nil
    connection.cancel()
    let callback = onClose
    onPacket = nil
    onClose = nil
    callback?(reason)
  }

  private func readHeader() {
    read(count: 5) { [weak self] bytes in
      guard let self else { return }
      do {
        let header = try MirrorRelayPacket.header(bytes)
        if header.kind == .ping || header.kind == .pong {
          if header.kind == .ping { self.send(MirrorRelayPacket(kind: .pong, payload: Data())) }
          self.readHeader()
          return
        }
        self.read(count: header.length) { [weak self] payload in
          guard let self else { return }
          self.onPacket?(MirrorRelayPacket(kind: header.kind, payload: payload))
          if !self.closed { self.readHeader() }
        }
      } catch { self.close(error.localizedDescription) }
    }
  }

  private func read(count: Int, completion: @escaping @MainActor (Data) -> Void) {
    connection.receive(minimumIncompleteLength: count, maximumLength: count) {
      [weak self] data, _, _, error in
      Task { @MainActor in
        guard let self, !self.closed else { return }
        guard let data, data.count == count, error == nil else {
          self.close(error?.localizedDescription ?? "Display relay disconnected.")
          return
        }
        completion(data)
      }
    }
  }
}
