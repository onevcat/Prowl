import Foundation
import Observation

/// Non-secret facts about a paired Host. The device credential stays in Keychain.
nonisolated struct MirrorKnownHost: Codable, Equatable, Identifiable, Sendable {
  var address: String
  var port: UInt16
  var alias: String?
  var hostID: UUID?
  var pairedAt: Date?
  var lastConnectedAt: Date?

  var id: String { endpointID }
  var endpointID: String { address + ":" + String(port) }
  var displayName: String {
    let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return alias.isEmpty ? endpointID : alias
  }
  var connection: MirrorSavedConnection {
    MirrorSavedConnection(address: address, port: port, pairingKey: "", credential: nil)
  }

  static func endpointID(address: String, port: UInt16) -> String { address + ":" + String(port) }
}

/// Hover previews read this in-memory list. Keychain is touched only for a one-time
/// import of records written before this store existed, and when forgetting a Host.
@MainActor @Observable
final class MirrorKnownHostStore {
  private(set) var hosts: [MirrorKnownHost] = []
  private(set) var notice: String?
  private(set) var hasImportedLegacy: Bool
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let importLegacy: () throws -> [MirrorSavedConnection]
  @ObservationIgnored private let removeCredential: (MirrorSavedConnection) throws -> Void
  private static let hostsKey = "remoteMirrorKnownHosts"
  private static let importedKey = "remoteMirrorKnownHostsImported"

  init(
    defaults: UserDefaults = .standard,
    importLegacy: @escaping () throws -> [MirrorSavedConnection] = { try MirrorSavedConnection.loadAll() },
    removeCredential: @escaping (MirrorSavedConnection) throws -> Void = { try $0.forget() }
  ) {
    self.defaults = defaults
    self.importLegacy = importLegacy
    self.removeCredential = removeCredential
    hasImportedLegacy = defaults.bool(forKey: Self.importedKey)
    if let data = defaults.data(forKey: Self.hostsKey),
      let saved = try? JSONDecoder().decode([MirrorKnownHost].self, from: data)
    {
      hosts = Self.sorted(saved)
    }
  }

  func isKnown(address: String, port: UInt16) -> Bool {
    hosts.contains { $0.endpointID == MirrorKnownHost.endpointID(address: address, port: port) }
  }

  func host(address: String, port: UInt16) -> MirrorKnownHost? {
    hosts.first { $0.endpointID == MirrorKnownHost.endpointID(address: address, port: port) }
  }

  /// Runs after an explicit click, never on hover. A failed import can be retried.
  func importLegacyIfNeeded() {
    guard !hasImportedLegacy else { return }
    do {
      let legacy = try importLegacy()
      for record in legacy where !isKnown(address: record.address, port: record.port) {
        upsert(MirrorKnownHost(address: record.address, port: record.port, hostID: record.credential?.hostID))
      }
      hasImportedLegacy = true
      defaults.set(true, forKey: Self.importedKey)
      notice = nil
    } catch {
      SupaLogger("RemoteMirror").warning("Saved Host import failed: \(error)")
      notice = String(
        localized: "Previously paired Hosts could not be read. Use Connect to a New Host to continue."
      )
    }
  }

  func recordEnrollment(_ connection: MirrorSavedConnection) {
    var host =
      self.host(address: connection.address, port: connection.port)
      ?? MirrorKnownHost(address: connection.address, port: connection.port)
    host.hostID = connection.credential?.hostID ?? host.hostID
    host.pairedAt = Date()
    upsert(host)
  }

  func recordConnection(address: String, port: UInt16, hostID: UUID?) {
    var host = self.host(address: address, port: port) ?? MirrorKnownHost(address: address, port: port)
    host.hostID = hostID ?? host.hostID
    host.lastConnectedAt = Date()
    upsert(host)
  }

  func rename(_ id: MirrorKnownHost.ID, alias: String) {
    guard var host = hosts.first(where: { $0.id == id }) else { return }
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    host.alias = trimmed.isEmpty ? nil : trimmed
    upsert(host)
  }

  func forget(_ id: MirrorKnownHost.ID) {
    guard let host = hosts.first(where: { $0.id == id }) else { return }
    do {
      try removeCredential(host.connection)
      hosts.removeAll { $0.id == id }
      persist()
      notice = nil
    } catch {
      SupaLogger("RemoteMirror").warning("Forgetting a Host failed: \(error)")
      notice = String(localized: "Could not remove the saved access for \(host.displayName). Try again.")
    }
  }

  private func upsert(_ host: MirrorKnownHost) {
    var next = hosts.filter { $0.id != host.id }
    next.append(host)
    hosts = Self.sorted(next)
    persist()
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(hosts) {
      defaults.set(data, forKey: Self.hostsKey)
    }
  }

  private static func sorted(_ hosts: [MirrorKnownHost]) -> [MirrorKnownHost] {
    hosts.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }
}
