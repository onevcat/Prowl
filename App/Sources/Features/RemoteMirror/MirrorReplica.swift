import AppKit
import Foundation
import GhosttyKit
import Network
import Observation

@MainActor
@Observable
final class MirrorReplica {
  private(set) var usesStyledScrollback = false
  private(set) var view: GhosttySurfaceView?
  private(set) var displaySize = CGSize(width: 800, height: 600)
  var onMessage: ((MirrorMessage) -> Void)?
  var onFailure: ((String) -> Void)?
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var peer: MirrorRelayConnection?
  @ObservationIgnored private var candidate: MirrorRelayConnection?
  @ObservationIgnored private let runtime: GhosttyRuntime
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private var parseTimeout: Task<Void, Never>?
  @ObservationIgnored private let token = UUID().uuidString + UUID().uuidString
  @ObservationIgnored private var pending: MirrorMessage?
  @ObservationIgnored private var pendingScrollback: MirrorStyledScrollback?
  @ObservationIgnored private var pendingViewportText: String?
  @ObservationIgnored private var displayedScrollback: MirrorStyledScrollback?
  @ObservationIgnored private var expectedViewportText: String?
  @ObservationIgnored private var presentationPaused = false
  @ObservationIgnored private var presentationTask: Task<Void, Never>?
  @ObservationIgnored private var presentationMarker: String?
  @ObservationIgnored private var displayedMessage: MirrorMessage?
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var needsRestart = false

  init(runtime: GhosttyRuntime, clock: any Clock<Duration> = ContinuousClock()) {
    self.runtime = runtime
    self.clock = clock
  }

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
          guard let port = listener?.port, let executable = ProwlPaths.bundledMirrorRelayURL,
            FileManager.default.isExecutableFile(atPath: executable.path)
          else {
            self.fail(String(localized: "Cannot start display replica."))
            return
          }
          let command =
            "'\(executable.path.replacing("'", with: "'\\''"))' \(port.rawValue) \(self.token)"
          self.view = GhosttySurfaceView(
            runtime: self.runtime, workingDirectory: nil,
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW, command: command)
          self.view?.bridge.consumeWorkingDirectory = { [weak self] path in
            guard let self, path == self.presentationMarker else { return false }
            self.didParseFrame()
            return true
          }
          // Ghostty can also derive a title from OSC 7. Do not expose private markers.
          self.view?.bridge.consumeTitle = { [weak self] title in
            guard let self else { return false }
            return title.hasPrefix("/prowl-replica-\(self.token)-")
          }
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

  func display(
    _ message: MirrorMessage, styledScrollback: MirrorStyledScrollback? = nil,
    viewportText: String? = nil
  ) {
    guard let frame = message.frame, frame.columns >= 1, frame.columns <= 1000,
      frame.rows >= 1, frame.rows <= 1000
    else {
      onFailure?(String(localized: "Invalid Host terminal dimensions."))
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
      guard styledScrollback?.isValid != false else {
        fail(String(localized: "Invalid Host viewport frame."))
        return
      }
      if styledScrollback != nil || usesStyledScrollback {
        presentationPaused = true
        view?.setOcclusion(false)
      }
      displayedMessage = message
      displayedScrollback = styledScrollback
      expectedViewportText = viewportText
      let marker = "/prowl-replica-\(token)-\(sequence)"
      presentationMarker = marker
      parseTimeout?.cancel()
      let clock = clock
      parseTimeout = Task { @MainActor [weak self] in
        do { try await clock.sleep(for: .seconds(30)) } catch { return }
        guard let self, self.presentationMarker == marker else { return }
        self.fail(String(localized: "Display replica timed out while parsing a Host frame. Reconnect to try again."))
      }
      var payload = MirrorRelayPacket.sequenceBytes(sequence)
      payload.append(frame.bytes)
      if let styledScrollback {
        // Establish the live input modes first, then replace the display with
        // the archive. The exporter omits trailing empty rows, so pad one
        // viewport and position from the retained buffer's start, not its end.
        payload.append(Data("\u{1b}[H\u{1b}[2J\u{1b}[3J\u{1b}[0m".utf8))
        payload.append(styledScrollback.bytes)
        payload.append(Data(String(repeating: "\r\n", count: Int(frame.rows)).utf8))
        payload.append(Data("\u{1b}[?25l".utf8))
      }
      // Unlike title callbacks, OSC 7 remains available with a static title and after config reloads.
      payload.append(Data("\u{1b}]7;file://localhost\(marker)\u{7}".utf8))
      peer.send(MirrorRelayPacket(kind: .frame, payload: payload))
    } else {
      pending = message
      pendingScrollback = styledScrollback
      pendingViewportText = viewportText
    }
  }

  private func didParseFrame() {
    guard let message = displayedMessage, let sequence = message.sequence,
      let lease = message.subscriptionID, let terminal = view?.surface
    else { return }
    presentationMarker = nil
    parseTimeout?.cancel()
    parseTimeout = nil
    guard let scrollback = displayedScrollback else {
      usesStyledScrollback = false
      resumeRendering()
      onMessage?(.acknowledge(.init(sequence: sequence, subscriptionID: lease)))
      return
    }
    let top = "scroll_to_top"
    let scroll = "scroll_page_lines:\(scrollback.rowOffset)"
    guard ghostty_surface_binding_action(terminal, top, UInt(top.utf8.count)),
      ghostty_surface_binding_action(terminal, scroll, UInt(scroll.utf8.count))
    else {
      fail(String(localized: "Invalid Host viewport frame."))
      return
    }
    // Scroll bindings enqueue IO work too. Verify after that queue advances,
    // rather than acknowledging the still-visible bottom of the archive.
    presentationTask = Task { @MainActor [weak self] in
      var verified = false
      for _ in 0..<50 {
        do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        guard let self, !self.stopped, self.displayedMessage?.sequence == sequence,
          let terminal = self.view?.surface, let frame = message.frame
        else { return }
        if let text = try? GhosttyMirrorPaneSource.viewportText(
          terminal, columns: frame.columns, rows: frame.rows, preserveRows: true),
          text == self.expectedViewportText
        {
          verified = true
          break
        }
      }
      guard let self, !Task.isCancelled, !self.stopped else { return }
      self.usesStyledScrollback = verified
      self.resumeRendering()
      self.presentationTask = nil
      self.onMessage?(.acknowledge(.init(sequence: sequence, subscriptionID: lease)))
    }
  }

  private func resumeRendering() {
    guard presentationPaused else { return }
    presentationPaused = false
    view?.setOcclusion(view?.window?.occlusionState.contains(.visible) == true)
  }

  func stop() {
    stopped = true
    parseTimeout?.cancel()
    parseTimeout = nil
    presentationTask?.cancel()
    presentationTask = nil
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
    pendingScrollback = nil
    pendingViewportText = nil
    displayedScrollback = nil
    expectedViewportText = nil
    presentationMarker = nil
    presentationPaused = false
    usesStyledScrollback = false
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
          candidate.close(String(localized: "Invalid display relay."))
          return
        }
        self.peer = candidate
        self.candidate = nil
        self.listener?.cancel()
        self.listener = nil
        if let pending = self.pending {
          self.pending = nil
          self.display(
            pending, styledScrollback: self.pendingScrollback,
            viewportText: self.pendingViewportText)
          self.pendingScrollback = nil
          self.pendingViewportText = nil
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
            sequence <= (displayed.sequence ?? 0)
          else {
            candidate.close(String(localized: "Invalid display acknowledgement."))
            return
          }
        // PTY write completion precedes parsing. The private OSC marker
        // above is the presentation barrier, including history positioning.
        default: candidate.close(String(localized: "Invalid display relay message."))
        }
      }
    }
    candidate.onClose = { [weak self, weak candidate] error in
      guard let self, let candidate, !self.stopped,
        self.peer === candidate || self.candidate === candidate
      else { return }
      self.fail(error ?? String(localized: "Display replica disconnected."))
    }
    candidate.start()
  }
}
