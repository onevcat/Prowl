import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CLIKeyCommandHandlerTests {

  // MARK: - Helpers

  private static let testPaneID = UUID(uuidString: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764")!
  private static let testTabID = UUID(uuidString: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0")!

  private static func makeTarget() -> KeyResolvedTarget {
    KeyResolvedTarget(
      worktreeID: "Prowl:/Users/onevcat/Projects/Prowl",
      worktreeName: "Prowl",
      worktreePath: "/Users/onevcat/Projects/Prowl",
      worktreeRootPath: "/Users/onevcat/Projects/Prowl",
      worktreeKind: .git,
      tabID: testTabID,
      tabTitle: "Prowl 1",
      tabSelected: true,
      paneID: testPaneID,
      paneTitle: "zsh",
      paneCWD: "/Users/onevcat/Projects/Prowl",
      paneFocused: true
    )
  }

  private static func makeHandler(
    resolveResult: Result<KeyResolvedTarget, TargetResolverError> = .success(makeTarget()),
    deliverySuccess: Bool = true,
    keyDelivery: (@MainActor (KeyResolvedTarget, String, Int) -> KeyDeliveryResult)? = nil
  ) -> KeyCommandHandler {
    KeyCommandHandler(
      resolveProvider: { _ in resolveResult },
      keyDelivery: keyDelivery ?? { _, _, repeatCount in
        KeyDeliveryResult(
          attempted: repeatCount,
          delivered: deliverySuccess ? repeatCount : 0
        )
      }
    )
  }

  private static func makeEnvelope(
    rawToken: String = "enter",
    token: String = "enter",
    repeatCount: Int = 1,
    selector: TargetSelector = .none
  ) -> CommandEnvelope {
    CommandEnvelope(
      output: .json,
      command: .key(
        KeyInput(
          selector: selector,
          rawToken: rawToken,
          token: token,
          repeatCount: repeatCount
        ))
    )
  }

  // MARK: - Success tests

  @Test func successfulKeyDelivery() async throws {
    let handler = Self.makeHandler()
    let response = await handler.handle(envelope: Self.makeEnvelope())

    #expect(response.ok)
    #expect(response.command == "key")
    #expect(response.schemaVersion == "prowl.cli.key.v1")

    let payload = try #require(try response.data?.decode(as: KeyCommandPayload.self))
    #expect(payload.requested.token == "enter")
    #expect(payload.requested.repeat == 1)
    #expect(payload.key.normalized == "enter")
    #expect(payload.key.category == .editing)
    #expect(payload.delivery.attempted == 1)
    #expect(payload.delivery.delivered == 1)
    #expect(payload.delivery.mode == "keyDownUp")
    #expect(payload.target.worktree.id == "Prowl:/Users/onevcat/Projects/Prowl")
    #expect(payload.target.worktree.kind == "git")
    #expect(payload.target.tab.id == Self.testTabID.uuidString)
    #expect(payload.target.tab.selected == true)
    #expect(payload.target.pane.id == Self.testPaneID.uuidString)
    #expect(payload.target.pane.focused == true)
  }

  @Test func repeatCountPassesThroughToDelivery() async throws {
    var deliveredRepeatCount: Int?
    let handler = Self.makeHandler(
      keyDelivery: { _, _, repeatCount in
        deliveredRepeatCount = repeatCount
        return KeyDeliveryResult(attempted: repeatCount, delivered: repeatCount)
      }
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(repeatCount: 5)
    )

    #expect(response.ok)
    #expect(deliveredRepeatCount == 5)
    let payload = try #require(try response.data?.decode(as: KeyCommandPayload.self))
    #expect(payload.requested.repeat == 5)
    #expect(payload.delivery.attempted == 5)
    #expect(payload.delivery.delivered == 5)
  }

  @Test func rawTokenPreservedInResponse() async throws {
    let handler = Self.makeHandler()
    let response = await handler.handle(
      envelope: Self.makeEnvelope(rawToken: "Return", token: "enter")
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: KeyCommandPayload.self))
    #expect(payload.requested.token == "Return")
    #expect(payload.key.normalized == "enter")
  }

  @Test func deliveryReceivesCorrectTokenAndTarget() async throws {
    var deliveredToken: String?
    var deliveredTarget: KeyResolvedTarget?
    let handler = Self.makeHandler(
      keyDelivery: { target, token, repeatCount in
        deliveredTarget = target
        deliveredToken = token
        return KeyDeliveryResult(attempted: repeatCount, delivered: repeatCount)
      }
    )
    _ = await handler.handle(
      envelope: Self.makeEnvelope(token: "ctrl-c")
    )

    #expect(deliveredToken == "ctrl-c")
    #expect(deliveredTarget?.paneID == Self.testPaneID)
  }

  // MARK: - Category tests

  @Test func navigationCategory() async throws {
    let handler = Self.makeHandler()
    let response = await handler.handle(
      envelope: Self.makeEnvelope(token: "up")
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: KeyCommandPayload.self))
    #expect(payload.key.category == .navigation)
  }

  @Test func controlCategory() async throws {
    let handler = Self.makeHandler()
    let response = await handler.handle(
      envelope: Self.makeEnvelope(token: "ctrl-c")
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: KeyCommandPayload.self))
    #expect(payload.key.category == .control)
  }

  @Test func editingCategory() async throws {
    let handler = Self.makeHandler()
    let response = await handler.handle(
      envelope: Self.makeEnvelope(token: "backspace")
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: KeyCommandPayload.self))
    #expect(payload.key.category == .editing)
  }

  // MARK: - Error tests

  @Test func deliveryFailureReturnsError() async throws {
    let handler = Self.makeHandler(deliverySuccess: false)
    let response = await handler.handle(
      envelope: Self.makeEnvelope(repeatCount: 3)
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.keyDeliveryFailed)
  }

  @Test func partialDeliveryReturnsError() async throws {
    let handler = Self.makeHandler(
      keyDelivery: { _, _, repeatCount in
        KeyDeliveryResult(attempted: repeatCount, delivered: repeatCount - 1)
      }
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(repeatCount: 3)
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.keyDeliveryFailed)
  }

  @Test func noActivePaneWhenNoSelector() async throws {
    let handler = Self.makeHandler(
      resolveResult: .failure(.notFound("No focused pane in selected tab."))
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(selector: .none)
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.noActivePane)
  }

  @Test func targetNotFoundWithExplicitSelector() async throws {
    let handler = Self.makeHandler(
      resolveResult: .failure(.notFound("Worktree 'missing' not found."))
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(selector: .worktree("missing"))
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.targetNotFound)
  }

  @Test func targetNotUniqueError() async throws {
    let handler = Self.makeHandler(
      resolveResult: .failure(.notUnique("Worktree 'Prowl' matches 2 worktrees."))
    )
    let response = await handler.handle(
      envelope: Self.makeEnvelope(selector: .worktree("Prowl"))
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.targetNotUnique)
  }

  @Test func unsupportedKeyReturnsError() async throws {
    let handler = Self.makeHandler()
    let response = await handler.handle(
      envelope: Self.makeEnvelope(token: "hyper-k")
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.unsupportedKey)
  }
}
