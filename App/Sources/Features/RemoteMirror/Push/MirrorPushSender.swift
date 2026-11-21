import Foundation
import Observation

/// Sends push events for the Mirror Host (docs-ai 095 P2). It does nothing, and contacts
/// nobody, unless Remote Mirror is on, the Host runs, **Send Notifications to Paired Devices**
/// is on, and a paired device has a registration that the Mac allows.
@MainActor
final class MirrorPushSender {
  struct PaneDetails: Sendable {
    let title: String
    let stateChangedAt: String?
  }

  private let host: MirrorHost
  private let enabled: () -> Bool
  private let paneStates: () -> [UUID: MirrorPushPlanner.PaneState]
  private let paneDetails: (UUID) -> PaneDetails?
  private let presence: MacPresenceMonitor
  /// `nil` when no push service is configured: the sender then never starts.
  private let gateway: (any MirrorPushGateway)?
  private let clock: ContinuousClock

  private var planner = MirrorPushPlanner()
  private var knownPaneStates: [UUID: MirrorPushPlanner.PaneState] = [:]
  private var onlineDevices: Set<UUID> = []
  private(set) var isActive = false
  private var hostObservation: Task<Void, Never>?
  private var paneObservation: Task<Void, Never>?
  /// In-flight gateway requests; each removes itself when it ends.
  private var sends: [UUID: Task<Void, Never>] = [:]

  init(
    host: MirrorHost, enabled: @escaping () -> Bool,
    paneStates: @escaping () -> [UUID: MirrorPushPlanner.PaneState],
    paneDetails: @escaping (UUID) -> PaneDetails?,
    presence: MacPresenceMonitor, gateway: (any MirrorPushGateway)?, clock: ContinuousClock = ContinuousClock()
  ) {
    self.host = host
    self.enabled = enabled
    self.paneStates = paneStates
    self.paneDetails = paneDetails
    self.presence = presence
    self.gateway = gateway
    self.clock = clock
    presence.onChange = { [weak self] present in self?.presenceChanged(present) }
  }

  /// Follows the Host and the panes with Observation until `stop()`.
  func start() {
    guard hostObservation == nil else { return }
    hostObservation = Task { [weak self] in
      while !Task.isCancelled {
        // Hold the sender only while refreshing, not while waiting for the next change.
        let observing = await withCheckedContinuation { continuation in
          guard let sender = self else {
            continuation.resume(returning: false)
            return
          }
          withObservationTracking {
            sender.refresh()
          } onChange: {
            continuation.resume(returning: true)
          }
        }
        guard observing else { return }
      }
    }
  }

  func stop() {
    hostObservation?.cancel()
    hostObservation = nil
    deactivate()
    for send in sends.values { send.cancel() }
    sends.removeAll()
  }

  /// Waits for the gateway requests started so far.
  func settle() async {
    for send in Array(sends.values) { await send.value }
  }

  /// Reads the Host state and the panes, and acts on what changed.
  func refresh() {
    let devices = eligibleDevices()
    let shouldBeActive = gateway != nil && enabled() && host.isRunning && host.pushEnabled && !devices.isEmpty
    guard shouldBeActive else {
      deactivate()
      return
    }
    if !isActive { activate() }
    let online = Set(devices.filter(\.isOnline).map(\.id))
    for device in devices where onlineDevices.contains(device.id) && !online.contains(device.id) {
      send(planner.deviceWentOffline(device))
    }
    onlineDevices = online
    let states = paneStates()
    let now = clock.now
    for (paneID, state) in states where knownPaneStates[paneID] != state {
      send(planner.paneChanged(paneID, to: state, at: now, devices: devices))
    }
    for paneID in knownPaneStates.keys where states[paneID] == nil {
      planner.paneRemoved(paneID, at: now)
    }
    knownPaneStates = states
  }

  private func activate() {
    isActive = true
    // The states at activation are the starting point, not events. The planner keeps what it
    // knew before a stop, so an open prompt that was never pushed is still held.
    let devices = eligibleDevices()
    knownPaneStates = paneStates()
    planner.activate(states: knownPaneStates, at: clock.now, devices: devices)
    onlineDevices = Set(devices.filter(\.isOnline).map(\.id))
    presence.start()
    send(planner.presenceChanged(to: presence.isPresent, devices: devices))
  }

  private func deactivate() {
    guard isActive else { return }
    isActive = false
    presence.stop()
    knownPaneStates = [:]
    onlineDevices = []
  }

  private func presenceChanged(_ present: Bool) {
    guard isActive else { return }
    send(planner.presenceChanged(to: present, devices: eligibleDevices()))
  }

  private func eligibleDevices() -> [MirrorPushPlanner.Device] {
    host.devices.compactMap { device in
      guard let push = device.push, device.isPushAllowedByMac else { return nil }
      return .init(id: device.id, kinds: push.kinds, isOnline: host.isOnline(device.id))
    }
  }

  /// Builds and sends each push in its own task, outside any Observation tracking, so reading
  /// the pane details does not make title changes wake the sender.
  private func send(_ pushes: [MirrorPushPlanner.Push]) {
    guard let gateway else { return }
    for push in pushes {
      let id = UUID()
      sends[id] = Task { [weak self] in
        defer { self?.sends.removeValue(forKey: id) }
        guard let self, let hostID = self.host.hostIdentityID,
          let device = self.host.devices.first(where: { $0.id == push.deviceID }), let token = device.push?.token,
          let request = Self.request(for: push, device: device, hostID: hostID, details: self.paneDetails(push.paneID))
        else { return }
        let result = await gateway.push(token: token, collapseID: request.collapseID, sealed: request.sealed)
        guard result == .tokenGone else { return }
        self.planner.forget(push.deviceID)
        self.host.dropPushRegistration(push.deviceID, token: token)
      }
    }
  }

  struct Request: Equatable {
    let collapseID: String
    let sealed: String
  }

  static func request(
    for push: MirrorPushPlanner.Push, device: MirrorPairedDevice, hostID: UUID, details: PaneDetails?
  ) -> Request? {
    let key = MirrorPushCrypto.key(deviceSecret: device.key, hostID: hostID)
    let content = MirrorPushContent(
      kind: push.kind, paneID: push.paneID, title: details?.title ?? String(localized: "Prowl"),
      body: push.kind == .blocked
        ? String(localized: "An agent needs your attention")
        : String(localized: "An agent finished"),
      stateChangedAt: details?.stateChangedAt)
    guard let plaintext = try? JSONEncoder().encode(content),
      let sealed = try? MirrorPushCrypto.seal(plaintext, key: key, hostID: hostID)
    else { return nil }
    return Request(collapseID: MirrorPushCrypto.collapseID(paneID: push.paneID, key: key), sealed: sealed)
  }
}
