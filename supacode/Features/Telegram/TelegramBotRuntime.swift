import Foundation

private nonisolated let telegramBotLogger = SupaLogger("TelegramBot")

struct TelegramBotConfiguration: Equatable, Sendable {
  var enabled: Bool
  var token: String?
  var allowedUserIDs: [Int64]
  var defaultReadLines: Int
  var requireExplicitPaneForWrite: Bool

  var activeToken: String? {
    let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  var canRun: Bool {
    enabled && activeToken != nil && !allowedUserIDs.isEmpty
  }

  var normalized: TelegramBotConfiguration {
    TelegramBotConfiguration(
      enabled: enabled,
      token: activeToken,
      allowedUserIDs: allowedUserIDs,
      defaultReadLines: max(1, min(defaultReadLines, 500)),
      requireExplicitPaneForWrite: requireExplicitPaneForWrite
    )
  }
}

@MainActor
struct TelegramBotUpdateProcessor {
  typealias Route = @MainActor @Sendable (CommandEnvelope) async -> CommandResponse
  typealias SendMessage = @MainActor @Sendable (_ chatID: Int64, _ text: String) async throws -> Void

  let configuration: TelegramBotConfiguration
  let parser: TelegramBotCommandParser
  let formatter: TelegramBotResponseFormatter
  let route: Route
  let sendMessage: SendMessage

  init(
    configuration: TelegramBotConfiguration,
    formatter: TelegramBotResponseFormatter = TelegramBotResponseFormatter(),
    route: @escaping Route,
    sendMessage: @escaping SendMessage
  ) {
    let normalized = configuration.normalized
    self.configuration = normalized
    self.parser = TelegramBotCommandParser(
      defaultReadLines: normalized.defaultReadLines,
      requireExplicitPaneForWrite: normalized.requireExplicitPaneForWrite
    )
    self.formatter = formatter
    self.route = route
    self.sendMessage = sendMessage
  }

  func process(updates: [TelegramBotUpdate]) async -> Int? {
    var nextOffset: Int?
    let allowedUserIDs = Set(configuration.allowedUserIDs)

    for update in updates {
      nextOffset = max(nextOffset ?? 0, update.updateID + 1)
      guard let message = update.message,
        let user = message.from,
        let text = message.text
      else {
        continue
      }

      guard allowedUserIDs.contains(user.id) else {
        telegramBotLogger.info("Rejected Telegram command from unauthorized user_id=\(user.id)")
        continue
      }

      switch parser.parse(text: text) {
      case .message(let responseText):
        await send(chatID: message.chat.id, text: responseText)

      case .command(let request):
        telegramBotLogger.info("Executing Telegram command type=\(request.commandName)")
        let response = await route(request.envelope)
        await send(chatID: message.chat.id, text: formatter.format(response))
      }
    }

    return nextOffset
  }

  private func send(chatID: Int64, text: String) async {
    do {
      try await sendMessage(chatID, text)
    } catch {
      telegramBotLogger.warning("Failed to send Telegram message: \(telegramBotLogMessage(for: error))")
    }
  }
}

@MainActor
final class TelegramBotRuntime {
  typealias Route = @MainActor @Sendable (CommandEnvelope) async -> CommandResponse
  typealias Sleep = @Sendable (Duration) async -> Void

  private let client: TelegramBotClient
  private let route: Route
  private let sleep: Sleep
  private var task: Task<Void, Never>?
  private var configuration: TelegramBotConfiguration = .init(
    enabled: false,
    token: nil,
    allowedUserIDs: [],
    defaultReadLines: 80,
    requireExplicitPaneForWrite: true
  )
  private var offset: Int?

  init(
    client: TelegramBotClient = .liveValue,
    route: @escaping Route,
    sleep: @escaping Sleep = { duration in
      try? await Task.sleep(for: duration)
    }
  ) {
    self.client = client
    self.route = route
    self.sleep = sleep
  }

  deinit {
    task?.cancel()
  }

  func apply(configuration newConfiguration: TelegramBotConfiguration) {
    let normalized = newConfiguration.normalized
    guard normalized.canRun else {
      stop()
      configuration = normalized
      return
    }

    if normalized != configuration {
      stop()
      configuration = normalized
      start()
    } else if task == nil {
      start()
    }
  }

  func stop() {
    guard task != nil else { return }
    task?.cancel()
    task = nil
    offset = nil
    telegramBotLogger.info("Telegram bot stopped")
  }

  func pollOnce(configuration: TelegramBotConfiguration, offset: Int?) async -> Int? {
    do {
      return try await pollOnceThrowing(configuration: configuration.normalized, offset: offset)
    } catch {
      telegramBotLogger.warning("Telegram poll failed: \(telegramBotLogMessage(for: error))")
      return offset
    }
  }

  private func start() {
    guard task == nil else { return }
    telegramBotLogger.info("Telegram bot started")
    task = Task { [weak self] in
      await self?.runLoop()
    }
  }

  private func runLoop() async {
    var backoffSeconds = 1
    while !Task.isCancelled {
      let currentConfiguration = configuration
      guard currentConfiguration.canRun else { return }
      do {
        offset = try await pollOnceThrowing(configuration: currentConfiguration, offset: offset)
        backoffSeconds = 1
      } catch {
        telegramBotLogger.warning("Telegram poll failed: \(telegramBotLogMessage(for: error))")
        await sleep(.seconds(backoffSeconds))
        backoffSeconds = min(backoffSeconds * 2, 60)
      }
    }
  }

  private func pollOnceThrowing(configuration: TelegramBotConfiguration, offset: Int?) async throws -> Int? {
    guard let token = configuration.activeToken else { return offset }
    let updates = try await client.getUpdates(token, offset, 30)
    guard !updates.isEmpty else { return offset }
    let processor = TelegramBotUpdateProcessor(
      configuration: configuration,
      route: route,
      sendMessage: { [client] chatID, text in
        try await client.sendMessage(token, chatID, text)
      }
    )
    return await processor.process(updates: updates) ?? offset
  }
}

private func telegramBotLogMessage(for error: Error) -> String {
  if let clientError = error as? TelegramBotClientError {
    switch clientError {
    case .invalidResponse:
      return "invalid_response"
    case .api(let errorCode, let description):
      if let errorCode {
        return "api_error code=\(errorCode) description=\(description)"
      }
      return "api_error description=\(description)"
    }
  }
  return "network_error"
}
