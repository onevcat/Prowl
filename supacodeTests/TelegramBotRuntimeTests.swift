import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct TelegramBotRuntimeTests {
  @Test func processorIgnoresUnauthorizedUsersAndAdvancesOffset() async {
    let routedCommands = LockIsolated<[String]>([])
    let sentMessages = LockIsolated<[String]>([])
    let processor = TelegramBotUpdateProcessor(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      route: { envelope in
        let commandName = envelope.command.name
        routedCommands.withValue { $0.append(commandName) }
        return CommandResponse(ok: true, command: commandName, schemaVersion: "prowl.cli.\(commandName).v1")
      },
      sendMessage: { _, text in
        sentMessages.withValue { $0.append(text) }
      }
    )
    let update = TelegramBotUpdate(
      updateID: 10,
      message: TelegramBotMessage(
        messageID: 1,
        from: TelegramBotUser(id: 7, isBot: false, firstName: "No", username: nil),
        chat: TelegramBotChat(id: 100),
        text: "/list"
      )
    )

    let nextOffset = await processor.process(updates: [update])

    #expect(nextOffset == 11)
    #expect(routedCommands.value.isEmpty)
    #expect(sentMessages.value.isEmpty)
  }

  @Test func processorRoutesAuthorizedCommandAndSendsFormattedResponse() async throws {
    let routedCommands = LockIsolated<[String]>([])
    let sentMessages = LockIsolated<[String]>([])
    let payload = ListCommandPayload(count: 0, items: [])
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(encoding: payload)
    )
    let processor = TelegramBotUpdateProcessor(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      route: { envelope in
        let commandName = envelope.command.name
        routedCommands.withValue { $0.append(commandName) }
        return response
      },
      sendMessage: { chatID, text in
        sentMessages.withValue { $0.append("\(chatID):\(text)") }
      }
    )
    let update = TelegramBotUpdate(
      updateID: 20,
      message: TelegramBotMessage(
        messageID: 1,
        from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
        chat: TelegramBotChat(id: 100),
        text: "/list"
      )
    )

    let nextOffset = await processor.process(updates: [update])

    #expect(nextOffset == 21)
    #expect(routedCommands.value == ["list"])
    #expect(sentMessages.value == ["100:No panes found."])
  }

  @Test func runtimePollOnceUsesGetUpdatesOffsetAndReturnsNextOffset() async {
    let requestedOffsets = LockIsolated<[Int?]>([])
    let sentMessages = LockIsolated<[String]>([])
    let client = TelegramBotClient(
      getMe: { _ in TelegramBotUser(id: 1, isBot: true, firstName: "Prowl", username: "prowl_bot") },
      getUpdates: { _, offset, timeout in
        requestedOffsets.withValue { $0.append(offset) }
        #expect(timeout == 30)
        return [
          TelegramBotUpdate(
            updateID: 123,
            message: TelegramBotMessage(
              messageID: 1,
              from: TelegramBotUser(id: 42, isBot: false, firstName: "Yes", username: nil),
              chat: TelegramBotChat(id: 100),
              text: "/agents"
            )
          )
        ]
      },
      sendMessage: { _, chatID, text in
        sentMessages.withValue { $0.append("\(chatID):\(text)") }
      }
    )
    let runtime = TelegramBotRuntime(
      client: client,
      route: { envelope in
        let commandName = envelope.command.name
        return CommandResponse(ok: true, command: commandName, schemaVersion: "prowl.cli.\(commandName).v1")
      },
      sleep: { _ in }
    )

    let nextOffset = await runtime.pollOnce(
      configuration: TelegramBotConfiguration(
        enabled: true,
        token: "secret",
        allowedUserIDs: [42],
        defaultReadLines: 80,
        requireExplicitPaneForWrite: true
      ),
      offset: 120
    )

    #expect(nextOffset == 124)
    #expect(requestedOffsets.value.count == 1)
    #expect(requestedOffsets.value[0] == 120)
    #expect(sentMessages.value.count == 1)
  }
}
