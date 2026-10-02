import Foundation

protocol LLMService: Sendable {
  var isAvailable: Bool { get }
  func generate(prompt: String) async throws -> String
}
