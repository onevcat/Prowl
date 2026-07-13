import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteControlAccessTokenStoreTests {
  @Test func loadOrCreateCreatesAndReusesBase64URLToken() throws {
    let storage = InMemoryTokenStorage()
    let store = RemoteControlAccessTokenStore(storage: storage)

    let created = try store.loadOrCreate()
    let loaded = try store.loadOrCreate()

    #expect(created == loaded)
    #expect(created.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    #expect(decodedBase64URL(created)?.count == 32)
    #expect(storage.secret == decodedBase64URL(created))
  }

  @Test func rotateReplacesStoredToken() throws {
    let storage = InMemoryTokenStorage()
    let store = RemoteControlAccessTokenStore(storage: storage)

    let original = try store.loadOrCreate()
    let rotated = try store.rotate()
    let reloaded = try RemoteControlAccessTokenStore(storage: storage).loadOrCreate()

    #expect(rotated != original)
    #expect(reloaded == rotated)
  }

  @Test func removeClearsStoredToken() throws {
    let storage = InMemoryTokenStorage()
    let store = RemoteControlAccessTokenStore(storage: storage)
    let original = try store.loadOrCreate()

    try store.remove()

    #expect(storage.secret == nil)
    #expect(try store.loadOrCreate() != original)
  }

  @Test func invalidStoredSecretIsReplaced() throws {
    let storage = InMemoryTokenStorage(secret: Data(repeating: 0, count: 31))
    let store = RemoteControlAccessTokenStore(storage: storage)

    let token = try store.loadOrCreate()

    #expect(decodedBase64URL(token)?.count == 32)
    #expect(storage.secret?.count == 32)
  }

  private func decodedBase64URL(_ token: String) -> Data? {
    let base64 = token.replacing("-", with: "+").replacing("_", with: "/")
    let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64 + padding)
  }
}

private final class InMemoryTokenStorage: RemoteControlAccessTokenSecretStorage,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var value: Data?

  init(secret: Data? = nil) {
    value = secret
  }

  var secret: Data? {
    lock.withLock { value }
  }

  func load() throws -> Data? {
    lock.withLock { value }
  }

  func save(_ secret: Data) throws {
    lock.withLock { value = secret }
  }

  func remove() throws {
    lock.withLock { value = nil }
  }
}
