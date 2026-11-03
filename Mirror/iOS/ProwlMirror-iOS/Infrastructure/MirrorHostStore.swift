import Foundation
import Observation

/// A paired Host as the phone remembers it. The device credential stays in Keychain under
/// `MirrorRemoteConnection`'s per-endpoint account; this record holds only what a list shows.
nonisolated struct MirrorHostRecord: Codable, Identifiable, Equatable, Hashable, Sendable {
  var id: UUID
  var alias: String?
  var address: String
  var port: UInt16
  var hostID: UUID?
  var pairedAt: Date
  var lastConnectedAt: Date?

  var displayName: String {
    if let alias, !alias.isEmpty { return alias }
    return address
  }

  var endpoint: String { "\(address):\(port)" }

  /// The Keychain account `MirrorRemoteConnection` restores the credential from.
  var credentialAccount: String { "host:\(address):\(port)" }

  /// A connection that relies on the saved credential.
  var configuration: MirrorSavedConnection { .init(address: address, port: port, pairingKey: "") }
}

/// The list of paired Hosts, persisted in `UserDefaults` (docs-ai 088). Records are keyed by
/// endpoint: pairing the same address again updates the entry instead of adding one.
@MainActor
@Observable
final class MirrorHostStore {
  static let defaultsKey = "mirror.hosts"

  private(set) var hosts: [MirrorHostRecord] = []
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.defaultsKey),
      let decoded = try? JSONDecoder().decode([MirrorHostRecord].self, from: data)
    {
      hosts = decoded
    }
    migrateLegacyConnection()
  }

  func host(id: UUID) -> MirrorHostRecord? { hosts.first { $0.id == id } }

  /// Records a verified connection; an existing entry for the endpoint keeps its alias.
  @discardableResult
  func upsert(address: String, port: UInt16, hostID: UUID?) -> MirrorHostRecord {
    if let index = hosts.firstIndex(where: { $0.address == address && $0.port == port }) {
      hosts[index].hostID = hostID ?? hosts[index].hostID
      hosts[index].lastConnectedAt = Date()
      persist()
      return hosts[index]
    }
    let record = MirrorHostRecord(
      id: UUID(), address: address, port: port, hostID: hostID, pairedAt: Date(), lastConnectedAt: Date())
    hosts.insert(record, at: 0)
    persist()
    return record
  }

  func touch(_ id: UUID) {
    guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
    hosts[index].lastConnectedAt = Date()
    persist()
  }

  func rename(_ id: UUID, alias: String) {
    guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    hosts[index].alias = trimmed.isEmpty ? nil : trimmed
    persist()
  }

  /// Forgets the Host and its device credential; the Host keeps the device until revoked there.
  func remove(_ id: UUID) {
    guard let record = host(id: id) else { return }
    hosts.removeAll { $0.id == id }
    persist()
    try? MirrorSavedConnection.remove(account: record.credentialAccount)
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(hosts) { defaults.set(data, forKey: Self.defaultsKey) }
  }

  /// Earlier builds remembered one Host under `last-verified-host`; adopt it once.
  private func migrateLegacyConnection() {
    guard hosts.isEmpty, let saved = try? MirrorSavedConnection.load(), let credential = saved.credential else {
      return
    }
    try? saved.save(account: "host:\(saved.address):\(saved.port)")
    hosts = [
      MirrorHostRecord(
        id: UUID(), address: saved.address, port: saved.port, hostID: credential.hostID, pairedAt: Date())
    ]
    persist()
  }
}
