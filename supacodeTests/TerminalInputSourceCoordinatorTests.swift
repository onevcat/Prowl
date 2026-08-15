import Foundation
import Testing

@testable import supacode

private enum MockInputSourceID {
  static let chinese = "com.example.inputmethod.Chinese"
}

@MainActor
private final class MockKeyboardInputSourceSelector: KeyboardInputSourceSelecting {
  var currentID = MockInputSourceID.chinese
  var selectedIDs: [String] = []

  func currentInputSourceID() -> String? {
    currentID
  }

  func selectInputSource(id: String) -> Bool {
    currentID = id
    selectedIDs.append(id)
    return true
  }

  func selectABC() -> Bool {
    selectInputSource(id: KeyboardInputSourceSelector.abcInputSourceID)
  }
}

@MainActor
struct TerminalInputSourceCoordinatorTests {
  @Test func commandLikeFocusSavesPreviousChatSourceAndSelectsABC() {
    let selector = MockKeyboardInputSourceSelector()
    let coordinator = TerminalInputSourceCoordinator(selector: selector)
    let agentSurface = UUID()
    let shellSurface = UUID()

    coordinator.applyFocusedContext(
      .chatAgent,
      targetID: .surface(agentSurface),
      reason: .focusChanged
    )
    selector.currentID = MockInputSourceID.chinese
    coordinator.applyFocusedContext(
      .commandLike,
      targetID: .surface(shellSurface),
      reason: .focusChanged
    )

    #expect(selector.currentID == KeyboardInputSourceSelector.abcInputSourceID)
    #expect(selector.selectedIDs == [KeyboardInputSourceSelector.abcInputSourceID])
  }

  @Test func returningToAgentRestoresSavedSource() {
    let selector = MockKeyboardInputSourceSelector()
    let coordinator = TerminalInputSourceCoordinator(selector: selector)
    let agentSurface = UUID()
    let shellSurface = UUID()

    coordinator.applyFocusedContext(
      .chatAgent,
      targetID: .surface(agentSurface),
      reason: .focusChanged
    )
    selector.currentID = MockInputSourceID.chinese
    coordinator.applyFocusedContext(
      .commandLike,
      targetID: .surface(shellSurface),
      reason: .focusChanged
    )
    coordinator.applyFocusedContext(
      .chatAgent,
      targetID: .surface(agentSurface),
      reason: .focusChanged
    )

    #expect(selector.currentID == MockInputSourceID.chinese)
    #expect(selector.selectedIDs.last == MockInputSourceID.chinese)
  }

  @Test func unknownFocusDoesNotChangeInputSource() {
    let selector = MockKeyboardInputSourceSelector()
    let coordinator = TerminalInputSourceCoordinator(selector: selector)
    let surface = UUID()

    coordinator.applyFocusedContext(.unknown, targetID: .surface(surface), reason: .appBecameActive)

    #expect(selector.currentID == MockInputSourceID.chinese)
    #expect(selector.selectedIDs.isEmpty)
  }

  @Test func chatAgentWithoutSavedSourceKeepsCurrentSource() {
    let selector = MockKeyboardInputSourceSelector()
    let coordinator = TerminalInputSourceCoordinator(selector: selector)
    let surface = UUID()

    coordinator.applyFocusedContext(.chatAgent, targetID: .surface(surface), reason: .focusChanged)

    #expect(selector.currentID == MockInputSourceID.chinese)
    #expect(selector.selectedIDs.isEmpty)
  }

  @Test func herdrPanesRememberIndependentChatInputSources() {
    let selector = MockKeyboardInputSourceSelector()
    let coordinator = TerminalInputSourceCoordinator(selector: selector)

    coordinator.applyFocusedContext(
      .chatAgent,
      targetID: .herdrPane("w1:p1"),
      reason: .focusChanged
    )
    selector.currentID = "com.example.inputmethod.PaneOne"
    coordinator.applyFocusedContext(
      .commandLike,
      targetID: .herdrPane("w1:p2"),
      reason: .focusChanged
    )
    coordinator.applyFocusedContext(
      .chatAgent,
      targetID: .herdrPane("w1:p2"),
      reason: .focusChanged
    )
    selector.currentID = "com.example.inputmethod.PaneTwo"
    coordinator.applyFocusedContext(
      .chatAgent,
      targetID: .herdrPane("w1:p1"),
      reason: .focusChanged
    )

    #expect(selector.selectedIDs.last == "com.example.inputmethod.PaneOne")
  }
}
