import Foundation

nonisolated struct CrossRepoPullRequestResponse: Decodable {
  let repositories: [String: CrossRepoPullRequestPayload]
  let errors: [CrossRepoPullRequestResponseError]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: TopLevelKey.self)
    self.errors =
      (try? container.decode([CrossRepoPullRequestResponseError].self, forKey: .errors)) ?? []
    if container.contains(.data),
      let dataContainer = try? container.nestedContainer(
        keyedBy: CrossRepoDynamicKey.self,
        forKey: .data
      )
    {
      var dict: [String: CrossRepoPullRequestPayload] = [:]
      for key in dataContainer.allKeys {
        if (try? dataContainer.decodeNil(forKey: key)) == true {
          continue
        }
        if let payload = try? dataContainer.decode(
          CrossRepoPullRequestPayload.self, forKey: key
        ) {
          dict[key.stringValue] = payload
        }
      }
      self.repositories = dict
    } else {
      self.repositories = [:]
    }
  }

  func errorMessagesByAlias() -> [String: String] {
    var messages: [String: String] = [:]
    for error in errors {
      guard let alias = error.path.first else {
        continue
      }
      let description = describeError(error)
      if let existing = messages[alias], !existing.isEmpty {
        messages[alias] = "\(existing); \(description)"
      } else {
        messages[alias] = description
      }
    }
    return messages
  }

  private func describeError(_ error: CrossRepoPullRequestResponseError) -> String {
    let message = error.message ?? "GraphQL error"
    if error.path.count > 1 {
      let field = error.path.dropFirst().joined(separator: ".")
      return "\(message) (at \(field))"
    }
    return message
  }

  private enum TopLevelKey: String, CodingKey {
    case data
    case errors
  }
}

nonisolated struct CrossRepoPullRequestPayload: Decodable {
  let pullRequestsByAlias: [String: GithubGraphQLPullRequestResponse.PullRequestConnection]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CrossRepoDynamicKey.self)
    var dict: [String: GithubGraphQLPullRequestResponse.PullRequestConnection] = [:]
    for key in container.allKeys {
      dict[key.stringValue] = try container.decode(
        GithubGraphQLPullRequestResponse.PullRequestConnection.self,
        forKey: key
      )
    }
    self.pullRequestsByAlias = dict
  }
}

nonisolated struct CrossRepoPullRequestResponseError: Decodable {
  let message: String?
  let path: [String]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    self.message = try container.decodeIfPresent(String.self, forKey: .message)
    var components: [String] = []
    if container.contains(.path),
      var unkeyed = try? container.nestedUnkeyedContainer(forKey: .path)
    {
      while !unkeyed.isAtEnd {
        if let value = try? unkeyed.decode(String.self) {
          components.append(value)
        } else if let value = try? unkeyed.decode(Int.self) {
          components.append("\(value)")
        } else {
          _ = try? unkeyed.decodeNil()
        }
      }
    }
    self.path = components
  }

  private enum Keys: String, CodingKey {
    case message
    case path
  }
}

nonisolated struct CrossRepoDynamicKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(intValue: Int) {
    self.stringValue = "\(intValue)"
    self.intValue = intValue
  }
}
