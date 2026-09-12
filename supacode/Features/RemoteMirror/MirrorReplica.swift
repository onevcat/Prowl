import AppKit
import Foundation
import GhosttyKit
import Network
import Observation

@MainActor
@Observable
final class MirrorReplica {
  private(set) var view: GhosttySurfaceView?
  private(set) var displaySize = CGSize(width: 800, height: 600)
  var onMessage: ((MirrorMessage) -> Void)?
  var onFailure: ((String) -> Void)?
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var peer: MirrorRelayConnection?
  @ObservationIgnored private var candidate: MirrorRelayConnection?
  @ObservationIgnored private let runtime: GhosttyRuntime
  @ObservationIgnored private let token = UUID().uuidString + UUID().uuidString
  @ObservationIgnored private var pending: MirrorMessage?
  @ObservationIgnored private var displayedMessage: MirrorMessage?
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var needsRestart = false

  init(runtime: GhosttyRuntime) { self.runtime = runtime }

  func start() throws {
    if needsRestart { stop() }
    guard listener == nil, peer == nil, view == nil else { return }
    stopped = false
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      Task { @MainActor in
        guard let self, !self.stopped, self.listener === listener else { return }
        switch state {
        case .ready:
          guard let port = listener?.port, let executable = SupacodePaths.bundledMirrorRelayURL,
            FileManager.default.isExecutableFile(atPath: executable.path)
          else {
            self.fail("Cannot start display replica.")
            return
          }
          let command =
            "'\(executable.path.replacing("'", with: "'\\''"))' \(port.rawValue) \(self.token)"
          self.view = GhosttySurfaceView(
            runtime: self.runtime, workingDirectory: nil,
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW, command: command)
        case .failed(let error): self.fail(error.localizedDescription)
        default: break
        }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection) }
    }
    listener.start(queue: .main)
  }

  func display(_ message: MirrorMessage) {
    guard let frame = message.frame, frame.columns >= 1, frame.columns <= 1000,
      frame.rows >= 1, frame.rows <= 1000
    else {
      onFailure?("Invalid Host terminal dimensions.")
      return
    }
    view?.mirrorGrid = (frame.columns, frame.rows)
    view?.updateSurfaceSize()
    if let surface = view?.surface {
      let size = ghostty_surface_size(surface)
      let scale = view?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
      displaySize = CGSize(
        width: CGFloat(size.width_px) / scale,
        height: CGFloat(size.height_px) / scale)
    }
    if let peer, let sequence = message.sequence {
      displayedMessage = message
      var payload = MirrorRelayPacket.sequenceBytes(sequence)
      payload.append(frame.bytes)
      peer.send(MirrorRelayPacket(kind: .frame, payload: payload))
    } else {
      pending = message
    }
  }

  func stop() {
    stopped = true
    needsRestart = false
    listener?.cancel()
    listener = nil
    peer?.close()
    peer = nil
    candidate?.close()
    candidate = nil
    view?.closeSurface()
    view = nil
    pending = nil
    displayedMessage = nil
  }

  private func fail(_ reason: String) {
    needsRestart = true
    onFailure?(reason)
  }

  private func accept(_ connection: NWConnection) {
    guard !stopped, candidate == nil, peer == nil else {
      connection.cancel()
      return
    }
    let candidate = MirrorRelayConnection(connection)
    self.candidate = candidate
    candidate.onPacket = { [weak self, weak candidate] packet in
      guard let self, let candidate,
        self.peer === candidate || self.candidate === candidate
      else { return }
      if self.peer == nil {
        // Code security: only the helper holding this replica token can forward input.
        guard packet.kind == .authenticate, packet.payload == Data(self.token.utf8) else {
          candidate.close("Invalid display relay.")
          return
        }
        self.peer = candidate
        self.candidate = nil
        self.listener?.cancel()
        self.listener = nil
        if let pending = self.pending {
          self.pending = nil
          self.display(pending)
        }
      } else {
        guard let displayed = self.displayedMessage, let lease = displayed.subscriptionID else {
          return
        }
        switch packet.kind {
        case .input:
          self.onMessage?(
            .input(.init(bytes: packet.payload, subscriptionID: lease)))
        case .acknowledge:
          guard let sequence = try? MirrorRelayPacket.sequence(packet.payload),
            sequence == displayed.sequence
          else {
            candidate.close("Invalid display acknowledgement.")
            return
          }
          self.onMessage?(
            .acknowledge(.init(sequence: sequence, subscriptionID: lease)))
        default: candidate.close("Invalid display relay message.")
        }
      }
    }
    candidate.onClose = { [weak self, weak candidate] error in
      guard let self, let candidate, !self.stopped,
        self.peer === candidate || self.candidate === candidate
      else { return }
      self.fail(error ?? "Display replica disconnected.")
    }
    candidate.start()
  }
}
