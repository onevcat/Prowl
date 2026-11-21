import Foundation

/// Decides which push events go out, from agent state changes, the user's presence at the Mac,
/// and which devices are connected (docs-ai 095 "Presence"). It holds no I/O, so every rule is
/// testable with plain values.
nonisolated struct MirrorPushPlanner {
  /// A pane entered `blocked` for the `ordinal`-th time; each opening is pushed at most once.
  struct Opening: Hashable, Sendable {
    let paneID: UUID
    let ordinal: Int
  }

  struct Push: Equatable, Sendable {
    let deviceID: UUID
    let paneID: UUID
    let kind: MirrorPushKind
  }

  /// What the planner needs to know about a device that may receive pushes.
  struct Device: Sendable {
    let id: UUID
    let kinds: Set<MirrorPushKind>
    let isOnline: Bool
  }

  /// `completed`: the agent finished a turn (OSC `done` or `error`, or a legacy busy-to-idle
  /// path). `idle`: not busy without a finished turn, such as an interrupt or a session reset.
  enum PaneState: Sendable {
    case working, blocked, completed, idle, none
  }

  /// `done` is pushed only after this much `working`, so short tool runs stay quiet.
  static let minimumWorking: Duration = .seconds(10)
  /// Agent detection can miss a pane for a moment. A pane that comes back in the same state
  /// within this time continues where it was, so one prompt is not pushed twice.
  static let redetectionGrace: Duration = .seconds(30)

  private var states: [UUID: PaneState] = [:]
  private var workingSince: [UUID: ContinuousClock.Instant] = [:]
  private var ordinals: [UUID: Int] = [:]
  private var missing: [UUID: (state: PaneState, since: ContinuousClock.Instant)] = [:]
  /// Openings held back for a device because the user was present or the device was online.
  private var held: [UUID: Set<Opening>] = [:]
  /// Openings already pushed to a device; only the latest opening of each pane is kept.
  private var delivered: [UUID: Set<Opening>] = [:]
  private(set) var isPresent = true

  init() {}

  /// A pane's agent state changed. `devices` are the devices that may receive pushes now.
  mutating func paneChanged(
    _ paneID: UUID, to state: PaneState, at now: ContinuousClock.Instant, devices: [Device]
  ) -> [Push] {
    var previous = states[paneID] ?? .none
    if let gap = missing.removeValue(forKey: paneID), gap.since.duration(to: now) < Self.redetectionGrace {
      guard gap.state != state else {
        // The same prompt is back: send what a catch-up during the gap could not.
        states[paneID] = state
        guard state == .blocked, !isPresent else { return [] }
        return devices.filter { !$0.isOnline }.flatMap { catchUp($0, paneID: paneID) }
      }
      previous = gap.state
    }
    guard previous != state else { return [] }
    states[paneID] = state
    if state == .working {
      workingSince[paneID] = now
    }
    if previous == .blocked {
      forgetOpenings(of: paneID)
    }
    switch state {
    case .blocked:
      let opening = open(paneID)
      var pushes: [Push] = []
      for device in devices where device.kinds.contains(.blocked) {
        if isPresent || device.isOnline {
          held[device.id, default: []].insert(opening)
        } else {
          delivered[device.id, default: []].insert(opening)
          pushes.append(Push(deviceID: device.id, paneID: paneID, kind: .blocked))
        }
      }
      return pushes
    case .completed:
      guard previous == .working, let since = workingSince.removeValue(forKey: paneID),
        since.duration(to: now) >= Self.minimumWorking, !isPresent
      else { return [] }
      return devices.filter { $0.kinds.contains(.done) && !$0.isOnline }
        .map { Push(deviceID: $0.id, paneID: paneID, kind: .done) }
    case .idle:
      workingSince.removeValue(forKey: paneID)
      return []
    case .working, .none:
      return []
    }
  }

  /// The pane is gone from the agent states: closed, or a short detection miss.
  mutating func paneRemoved(_ paneID: UUID, at now: ContinuousClock.Instant) {
    missing = missing.filter { $0.value.since.duration(to: now) < Self.redetectionGrace }
    guard let state = states.removeValue(forKey: paneID) else { return }
    missing[paneID] = (state, now)
  }

  /// The sender starts (again) with these states. Changes since the last start are taken
  /// silently, and a prompt that is still open and was never pushed to a device is held for it,
  /// so it goes out when the user leaves or the device goes offline.
  mutating func activate(states current: [UUID: PaneState], at now: ContinuousClock.Instant, devices: [Device]) {
    for (paneID, state) in current where states[paneID] != state {
      _ = paneChanged(paneID, to: state, at: now, devices: [])
    }
    for paneID in states.keys where current[paneID] == nil {
      paneRemoved(paneID, at: now)
    }
    for device in devices { deviceBecameEligible(device) }
  }

  /// A device can now receive `blocked` pushes (registered, allowed again, or asked for the
  /// kind). Open prompts it never got are held for it, as at activation; `done` is not replayed.
  mutating func deviceBecameEligible(_ device: Device) {
    guard device.kinds.contains(.blocked) else { return }
    for (paneID, state) in states where state == .blocked {
      let opening = Opening(paneID: paneID, ordinal: ordinals[paneID] ?? 0)
      if delivered[device.id]?.contains(opening) != true {
        held[device.id, default: []].insert(opening)
      }
    }
  }

  /// The user arrived at or left the Mac. Leaving sends the held openings of offline devices.
  mutating func presenceChanged(to present: Bool, devices: [Device]) -> [Push] {
    guard present != isPresent else { return [] }
    isPresent = present
    guard !present else { return [] }
    return devices.filter { !$0.isOnline }.flatMap { catchUp($0) }
  }

  /// A device's connection state changed. Going offline while the user is away sends its held
  /// openings.
  mutating func deviceWentOffline(_ device: Device) -> [Push] {
    isPresent ? [] : catchUp(device)
  }

  /// Forgets everything for a device, for example when it can no longer receive pushes.
  mutating func forget(_ deviceID: UUID) {
    held.removeValue(forKey: deviceID)
    delivered.removeValue(forKey: deviceID)
  }

  private mutating func open(_ paneID: UUID) -> Opening {
    let ordinal = (ordinals[paneID] ?? 0) + 1
    ordinals[paneID] = ordinal
    return Opening(paneID: paneID, ordinal: ordinal)
  }

  private mutating func forgetOpenings(of paneID: UUID) {
    for deviceID in held.keys { held[deviceID] = held[deviceID]?.filter { $0.paneID != paneID } }
    for deviceID in delivered.keys { delivered[deviceID] = delivered[deviceID]?.filter { $0.paneID != paneID } }
  }

  /// Sends the device's held openings that are still the latest prompt of a blocked pane.
  /// An opening whose pane is in a short detection gap stays held; others are dropped.
  private mutating func catchUp(_ device: Device, paneID only: UUID? = nil) -> [Push] {
    guard device.kinds.contains(.blocked), let openings = held[device.id] else { return [] }
    var keep: Set<Opening> = []
    var due: Set<Opening> = []
    for opening in openings {
      guard ordinals[opening.paneID] == opening.ordinal else { continue }
      if let only, opening.paneID != only {
        keep.insert(opening)
      } else if states[opening.paneID] == .blocked {
        due.insert(opening)
      } else if missing[opening.paneID]?.state == .blocked {
        keep.insert(opening)
      }
    }
    held[device.id] = keep.isEmpty ? nil : keep
    delivered[device.id, default: []].formUnion(due)
    return due.sorted { $0.paneID.uuidString < $1.paneID.uuidString }
      .map { Push(deviceID: device.id, paneID: $0.paneID, kind: .blocked) }
  }
}
