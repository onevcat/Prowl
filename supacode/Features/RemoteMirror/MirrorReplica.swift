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
  @ObservationIgnored private var peer: MirrorConnection?
  @ObservationIgnored private var candidate: MirrorConnection?
  @ObservationIgnored private let runtime: GhosttyRuntime
  @ObservationIgnored private let token = UUID().uuidString + UUID().uuidString
  @ObservationIgnored private var pending: MirrorMessage?
  @ObservationIgnored private var stopped = false

  init(runtime: GhosttyRuntime) { self.runtime = runtime }

  func start() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      Task { @MainActor in
        guard let self, !self.stopped else { return }
        switch state {
        case .ready:
          guard let port = listener?.port, let executable = Bundle.main.executableURL else {
            self.onFailure?("Cannot start display replica.")
            return
          }
          let command =
            "'\(executable.path.replacing("'", with: "'\\''"))' \(MirrorRelay.argument) \(port.rawValue) \(self.token)"
          self.view = GhosttySurfaceView(
            runtime: self.runtime, workingDirectory: nil,
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW, command: command)
        case .failed(let error): self.onFailure?(error.localizedDescription)
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
        width: CGFloat(frame.columns * size.cell_width_px) / scale,
        height: CGFloat(frame.rows * size.cell_height_px) / scale)
    }
    if let peer { peer.send(message) } else { pending = message }
  }

  func stop() {
    stopped = true
    listener?.cancel()
    listener = nil
    peer?.close()
    peer = nil
    candidate?.close()
    candidate = nil
    view?.closeSurface()
    view = nil
    pending = nil
  }

  private func accept(_ connection: NWConnection) {
    guard !stopped, candidate == nil, peer == nil else {
      connection.cancel()
      return
    }
    let candidate = MirrorConnection(connection)
    self.candidate = candidate
    candidate.onMessage = { [weak self, weak candidate] message in
      guard let self, let candidate else { return }
      if self.peer == nil {
        guard message.kind == .list, message.bytes == Data(self.token.utf8) else {
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
        self.onMessage?(message)
      }
    }
    candidate.onClose = { [weak self] error in
      guard let self, !self.stopped else { return }
      self.onFailure?(error ?? "Display replica disconnected.")
    }
    candidate.start()
  }
}
