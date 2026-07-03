import Dependencies
import Foundation

nonisolated struct TelegramBotUser: Codable, Equatable, Sendable {
  let id: Int64
  let isBot: Bool
  let firstName: String
  let username: String?

  enum CodingKeys: String, CodingKey {
    case id
    case isBot = "is_bot"
    case firstName = "first_name"
    case username
  }
}

nonisolated struct TelegramBotChat: Codable, Equatable, Sendable {
  let id: Int64
}

nonisolated struct TelegramBotMessage: Codable, Equatable, Sendable {
  let messageID: Int
  let from: TelegramBotUser?
  let chat: TelegramBotChat
  let text: String?

  enum CodingKeys: String, CodingKey {
    case messageID = "message_id"
    case from
    case chat
    case text
  }
}

nonisolated struct TelegramBotUpdate: Codable, Equatable, Sendable {
  let updateID: Int
  let message: TelegramBotMessage?

  enum CodingKeys: String, CodingKey {
    case updateID = "update_id"
    case message
  }
}

enum TelegramBotClientError: Error, Equatable, Sendable {
  case invalidResponse
  case api(errorCode: Int?, description: String)
}

struct TelegramBotClient: Sendable, DependencyKey {
  var getMe: @Sendable (_ token: String) async throws -> TelegramBotUser
  var getUpdates: @Sendable (_ token: String, _ offset: Int?, _ timeout: Int) async throws -> [TelegramBotUpdate]
  var sendMessage: @Sendable (_ token: String, _ chatID: Int64, _ text: String) async throws -> Void

  static let liveValue = TelegramBotClient(
    getMe: { token in
      try await TelegramBotHTTPClient.request(
        token: token,
        method: "getMe",
        queryItems: []
      )
    },
    getUpdates: { token, offset, timeout in
      var queryItems = [
        URLQueryItem(name: "timeout", value: String(timeout)),
        URLQueryItem(name: "allowed_updates", value: #"["message"]"#),
      ]
      if let offset {
        queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
      }
      return try await TelegramBotHTTPClient.request(
        token: token,
        method: "getUpdates",
        queryItems: queryItems
      )
    },
    sendMessage: { token, chatID, text in
      let _: TelegramBotMessage = try await TelegramBotHTTPClient.request(
        token: token,
        method: "sendMessage",
        queryItems: [
          URLQueryItem(name: "chat_id", value: String(chatID)),
          URLQueryItem(name: "text", value: text),
        ],
        httpMethod: "POST"
      )
    }
  )

  static let testValue = TelegramBotClient(
    getMe: { _ in
      throw TelegramBotClientError.invalidResponse
    },
    getUpdates: { _, _, _ in
      throw TelegramBotClientError.invalidResponse
    },
    sendMessage: { _, _, _ in
      throw TelegramBotClientError.invalidResponse
    }
  )
}

extension DependencyValues {
  var telegramBotClient: TelegramBotClient {
    get { self[TelegramBotClient.self] }
    set { self[TelegramBotClient.self] = newValue }
  }
}

private enum TelegramBotHTTPClient {
  static func request<Result: Decodable>(
    token: String,
    method: String,
    queryItems: [URLQueryItem],
    httpMethod: String = "GET"
  ) async throws -> Result {
    guard var components = URLComponents(string: "https://api.telegram.org/bot\(token)/\(method)") else {
      throw TelegramBotClientError.invalidResponse
    }

    var request: URLRequest
    if httpMethod == "GET" {
      components.queryItems = queryItems.isEmpty ? nil : queryItems
      guard let url = components.url else { throw TelegramBotClientError.invalidResponse }
      request = URLRequest(url: url)
    } else {
      guard let url = components.url else { throw TelegramBotClientError.invalidResponse }
      request = URLRequest(url: url)
      request.httpMethod = httpMethod
      request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
      request.httpBody = formURLEncoded(queryItems).data(using: .utf8)
    }

    let (data, _) = try await URLSession.shared.data(for: request)
    let decoded = try JSONDecoder().decode(TelegramBotAPIResponse<Result>.self, from: data)
    if decoded.success, let result = decoded.result {
      return result
    }
    throw TelegramBotClientError.api(
      errorCode: decoded.errorCode,
      description: decoded.description ?? "Telegram Bot API request failed."
    )
  }

  private static func formURLEncoded(_ queryItems: [URLQueryItem]) -> String {
    queryItems.map { item in
      let name = item.name.addingPercentEncoding(withAllowedCharacters: .telegramFormAllowed) ?? item.name
      let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: .telegramFormAllowed) ?? ""
      return "\(name)=\(value)"
    }
    .joined(separator: "&")
  }
}

extension CharacterSet {
  fileprivate static let telegramFormAllowed: CharacterSet = {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+")
    return allowed
  }()
}

nonisolated private struct TelegramBotAPIResponse<Result: Decodable>: Decodable {
  let success: Bool
  let result: Result?
  let description: String?
  let errorCode: Int?

  enum CodingKeys: String, CodingKey {
    case success = "ok"
    case result
    case description
    case errorCode = "error_code"
  }
}
