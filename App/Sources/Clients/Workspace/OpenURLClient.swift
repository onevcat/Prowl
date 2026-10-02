import AppKit
import ComposableArchitecture
import Foundation

struct OpenURLClient {
  var open: @MainActor @Sendable (_ url: URL) -> Void
}

extension OpenURLClient: DependencyKey {
  static let liveValue = OpenURLClient { url in
    NSWorkspace.shared.open(url)
  }

  static let testValue = OpenURLClient { _ in }
}

extension DependencyValues {
  var openURLClient: OpenURLClient {
    get { self[OpenURLClient.self] }
    set { self[OpenURLClient.self] = newValue }
  }
}
