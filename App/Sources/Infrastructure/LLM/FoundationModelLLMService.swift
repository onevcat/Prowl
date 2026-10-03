import Foundation
import FoundationModels

struct FoundationModelLLMService: LLMService {
  private static let timeout: Duration = .seconds(3)

  var isAvailable: Bool {
    SystemLanguageModel.default.isAvailable
  }

  func generate(prompt: String) async throws -> String {
    let session = LanguageModelSession()
    let response = try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        let result = try await session.respond(to: prompt)
        return result.content
      }
      group.addTask {
        try await Task.sleep(for: Self.timeout)
        throw CancellationError()
      }
      guard let first = try await group.next() else {
        throw CancellationError()
      }
      group.cancelAll()
      return first
    }
    return response
  }
}
