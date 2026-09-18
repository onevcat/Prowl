import AppKit
import GhosttyKit
import Testing

@testable import supacode

/// Config-to-dispatch for the no-terminal undo key: Ghostty resolves the
/// user's real `undo` / `redo` bindings (docs-ai 069.002, review round 2).
@MainActor
@Suite(.serialized)
struct GhosttyRuntimeAppKeyTests {
  @Test func defaultBindingsDispatchUndoAndRedo() {
    let runtime = makeRuntime(keybinds: [
      "super+z=undo", "super+shift+t=undo", "super+shift+z=redo",
    ])
    let calls = Calls()
    runtime.onAppUndo = {
      calls.undo += 1
      return true
    }
    runtime.onAppRedo = {
      calls.redo += 1
      return true
    }

    #expect(runtime.performAppUndoRedoBinding(for: key("z", [.command], code: 6)))
    #expect(runtime.performAppUndoRedoBinding(for: key("t", [.command, .shift], code: 17)))
    #expect(runtime.performAppUndoRedoBinding(for: key("z", [.command, .shift], code: 6)))
    #expect(calls.undo == 2)
    #expect(calls.redo == 1)
  }

  @Test func performableRebindingAndUnbindsAreHonored() {
    let runtime = makeRuntime(keybinds: [
      "super+z=unbind", "super+shift+t=unbind", "performable:super+u=undo",
    ])
    let calls = Calls()
    runtime.onAppUndo = {
      calls.undo += 1
      return true
    }

    #expect(runtime.performAppUndoRedoBinding(for: key("u", [.command], code: 32)))
    #expect(!runtime.performAppUndoRedoBinding(for: key("z", [.command], code: 6)))
    #expect(!runtime.performAppUndoRedoBinding(for: key("t", [.command, .shift], code: 17)))
    #expect(calls.undo == 1)
  }

  @Test func unboundUndoKeysDispatchNothing() {
    let runtime = makeRuntime(keybinds: ["super+z=unbind", "super+shift+t=unbind"])
    let calls = Calls()
    runtime.onAppUndo = {
      calls.undo += 1
      return true
    }

    #expect(!runtime.performAppUndoRedoBinding(for: key("z", [.command], code: 6)))
    #expect(!runtime.performAppUndoRedoBinding(for: key("t", [.command, .shift], code: 17)))
    #expect(calls.undo == 0)
  }

  @Test func anEmptyCloseHistoryLetsTheKeyThrough() {
    let runtime = makeRuntime(keybinds: ["super+z=undo"])
    runtime.onAppUndo = { false }

    #expect(!runtime.performAppUndoRedoBinding(for: key("z", [.command], code: 6)))
  }

  @Test func unrelatedBindingsAreNeitherUndoNorPerformed() {
    let runtime = makeRuntime(keybinds: ["super+z=undo", "super+shift+p=reload_config"])
    let calls = Calls()
    runtime.onAppUndo = {
      calls.undo += 1
      return true
    }

    #expect(!runtime.performAppUndoRedoBinding(for: key("p", [.command, .shift], code: 35)))
    #expect(!runtime.performAppUndoRedoBinding(for: key("q", [.command, .option, .control], code: 12)))
    #expect(calls.undo == 0)
    #expect(!runtime.isDispatchingUndoRedoKey)
  }

  @Test func appScopedUndoOutsideTheKeyDispatchStillReachesTheHandler() {
    let runtime = makeRuntime(keybinds: ["super+z=undo"])
    runtime.onAppUndo = { true }

    #expect(runtime.handleAppScopedAction(GHOSTTY_ACTION_UNDO) == true)
    #expect(runtime.handleAppScopedAction(GHOSTTY_ACTION_OPEN_CONFIG) == nil)
    runtime.isDispatchingUndoRedoKey = true
    #expect(runtime.handleAppScopedAction(GHOSTTY_ACTION_OPEN_CONFIG) == false)
    runtime.isDispatchingUndoRedoKey = false
  }

  private final class Calls {
    var undo = 0
    var redo = 0
  }

  private func makeRuntime(keybinds: [String]) -> GhosttyRuntime {
    let runtime = GhosttyRuntime()
    runtime.applyAppKeybindArguments(keybinds.map { "--keybind=\($0)" })
    return runtime
  }

  private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: flags,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: code
    )!
  }
}
