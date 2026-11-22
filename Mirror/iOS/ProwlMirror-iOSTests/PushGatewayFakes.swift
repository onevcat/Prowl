import CryptoKit
import DeviceCheck
import Foundation

@testable import ProwlMirror_iOS

final class FakeAttest: MirrorAppAttesting, @unchecked Sendable {
  let isSupported: Bool
  private let lock = NSLock()
  private var keys = 0
  private(set) var assertedHashes: [Data] = []
  /// Keys that this install no longer has (a reinstall): assertions with them fail.
  var lostKeys: Set<String> = []

  init(isSupported: Bool = true) { self.isSupported = isSupported }

  func generateKey() async throws -> String {
    lock.withLock {
      keys += 1
      return "key-\(keys)"
    }
  }

  func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { Data("attest:\(keyID)".utf8) }

  func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
    if lock.withLock({ lostKeys.contains(keyID) }) { throw DCError(.invalidKey) }
    lock.withLock { assertedHashes.append(clientDataHash) }
    return Data("assert:\(keyID)".utf8)
  }
}

/// Answers by "METHOD path"; challenges are numbered so each request can be matched.
final class FakeGateway: @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [String: [(Int, String)]] = [:]
  private var challenges = 0
  private var installations = 0
  private(set) var requests: [URLRequest] = []
  private var holds: Set<String> = []
  private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

  /// The next request to `route` waits until `release(route)`.
  func hold(_ route: String) { lock.withLock { _ = holds.insert(route) } }

  func release(_ route: String) {
    lock.withLock { waiting.removeValue(forKey: route) }?.resume()
  }

  func isWaiting(_ route: String) -> Bool { lock.withLock { waiting[route] != nil } }

  func answer(_ route: String, _ status: Int, _ body: String = "{}") {
    lock.withLock { answers[route, default: []].append((status, body)) }
  }

  func routes() -> [String] {
    lock.withLock { requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } }
  }

  var send: MirrorPushGatewayClient.Send {
    { request in
      let route = "\(request.httpMethod ?? "") \(request.url?.path() ?? "")"
      let held = self.lock.withLock {
        self.requests.append(request)
        return self.holds.remove(route) != nil
      }
      if held { await withCheckedContinuation { continuation in self.lock.withLock { self.waiting[route] = continuation } } }
      let (status, body, headers): (Int, String, [String: String]) = self.lock.withLock {
        if route == "POST /v1/challenge" {
          self.challenges += 1
          return (200, #"{"challenge":"c\#(self.challenges)"}"#, [:])
        }
        if route == "POST /v1/installations", self.answers[route]?.isEmpty ?? true {
          self.installations += 1
          return (201, #"{"installationID":"i\#(self.installations)"}"#, [:])
        }
        guard var queue = self.answers[route], !queue.isEmpty else { return (500, "{}", [:]) }
        let next = queue.removeFirst()
        self.answers[route] = queue
        return (next.0, next.1, next.0 == 429 ? ["Retry-After": "7"] : [:])
      }
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
      return (Data(body.utf8), response)
    }
  }
}

final class MemoryStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var value: MirrorPushInstallation?

  init(_ value: MirrorPushInstallation? = nil) { self.value = value }
  var current: MirrorPushInstallation? { lock.withLock { value } }
  var storage: MirrorPushInstallationStorage {
    MirrorPushInstallationStorage(
      load: { self.lock.withLock { self.value } }, save: { new in self.lock.withLock { self.value = new } })
  }
}

/// Yields until `condition` holds; bounded so a broken test fails instead of hanging.
@MainActor func eventually(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<10_000 {
    if condition() { return true }
    await Task.yield()
  }
  return condition()
}
