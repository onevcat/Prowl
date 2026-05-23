import Foundation
import Testing

@testable import supacode

@MainActor
struct CanvasFocusRestoreSelectionTests {
  @Test func returnsFocusedTabWhenFocusSuspensionEnds() {
    let focused = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)

    let result = canvasRestoredFocusTabID(
      wasSuspended: true,
      isSuspended: false,
      focusedTabID: focused
    )

    #expect(result == focused)
  }

  @Test func returnsNilWhenFocusRemainsSuspended() {
    let focused = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)

    let result = canvasRestoredFocusTabID(
      wasSuspended: true,
      isSuspended: true,
      focusedTabID: focused
    )

    #expect(result == nil)
  }

  @Test func returnsNilWhenSuspensionDidNotChange() {
    let focused = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!)

    let result = canvasRestoredFocusTabID(
      wasSuspended: false,
      isSuspended: false,
      focusedTabID: focused
    )

    #expect(result == nil)
  }

  @Test func returnsNilWhenNoFocusedTabExistsToRestore() {
    let result = canvasRestoredFocusTabID(
      wasSuspended: true,
      isSuspended: false,
      focusedTabID: nil
    )

    #expect(result == nil)
  }

  @Test func prefersSavedCanvasFocusTargetOverFallbackSelection() {
    let savedTabID = "00000000-0000-0000-0000-000000000201"
    let fallbackTabID = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!)

    let result = restoredCanvasFocusTarget(
      savedWorktreeID: "/tmp/repo/wt-2",
      savedTabID: savedTabID,
      fallbackWorktreeID: "/tmp/repo/wt-1",
      fallbackTabID: fallbackTabID
    )

    #expect(result?.worktreeID == "/tmp/repo/wt-2")
    #expect(result?.tabID.rawValue.uuidString == savedTabID.uppercased())
  }

  @Test func fallsBackWhenSavedCanvasTabIDIsInvalid() {
    let fallbackTabID = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!)

    let result = restoredCanvasFocusTarget(
      savedWorktreeID: "/tmp/repo/wt-2",
      savedTabID: "not-a-uuid",
      fallbackWorktreeID: "/tmp/repo/wt-1",
      fallbackTabID: fallbackTabID
    )

    #expect(result?.worktreeID == "/tmp/repo/wt-1")
    #expect(result?.tabID == fallbackTabID)
  }

  @Test func returnsNilWhenNeitherSavedNorFallbackCanvasFocusExists() {
    let result = restoredCanvasFocusTarget(
      savedWorktreeID: nil,
      savedTabID: nil,
      fallbackWorktreeID: nil,
      fallbackTabID: nil
    )

    #expect(result == nil)
  }

  @Test func activationFocusFallsBackToCanvasReturnWorktreeWhenTerminalSelectionIsCleared() {
    let selectedTabID = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!)
    let otherTabID = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!)

    let result = canvasActivationFocusTarget(
      selectedWorktreeID: nil,
      canvasReturnWorktreeID: "/tmp/repo/wt-2",
      candidates: [
        CanvasActivationFocusCandidate(worktreeID: "/tmp/repo/wt-1", selectedTabID: otherTabID),
        CanvasActivationFocusCandidate(worktreeID: "/tmp/repo/wt-2", selectedTabID: selectedTabID),
      ]
    )

    #expect(result?.worktreeID == "/tmp/repo/wt-2")
    #expect(result?.tabID == selectedTabID)
  }

  @Test func queuesCanvasFocusTargetWhenExternalTabChanges() {
    let target = CanvasExternalFocusTarget(
      worktreeID: "/tmp/repo/wt-1",
      tabID: TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!)
    )

    let result = canvasFocusTargetForTerminalFocusChange(
      isShowingCanvas: true,
      isTerminalFocusSuspended: false,
      focusTarget: target,
      currentFocusedWorktreeID: "/tmp/repo/wt-2",
      currentFocusedTabID: TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!)
    )

    #expect(result == target)
  }

  @Test func ignoresExternalFocusChangeWhenCanvasIsHidden() {
    let target = CanvasExternalFocusTarget(
      worktreeID: "/tmp/repo/wt-1",
      tabID: TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!)
    )

    let result = canvasFocusTargetForTerminalFocusChange(
      isShowingCanvas: false,
      isTerminalFocusSuspended: false,
      focusTarget: target,
      currentFocusedWorktreeID: nil,
      currentFocusedTabID: nil
    )

    #expect(result == nil)
  }

  @Test func ignoresExternalFocusChangeWhenCanvasAlreadyTracksSameTab() {
    let tabID = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!)
    let target = CanvasExternalFocusTarget(
      worktreeID: "/tmp/repo/wt-1",
      tabID: tabID
    )

    let result = canvasFocusTargetForTerminalFocusChange(
      isShowingCanvas: true,
      isTerminalFocusSuspended: false,
      focusTarget: target,
      currentFocusedWorktreeID: "/tmp/repo/wt-1",
      currentFocusedTabID: tabID
    )

    #expect(result == nil)
  }

  @Test func ignoresExternalFocusChangeWhileTerminalFocusIsSuspended() {
    let target = CanvasExternalFocusTarget(
      worktreeID: "/tmp/repo/wt-1",
      tabID: TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000305")!)
    )

    let result = canvasFocusTargetForTerminalFocusChange(
      isShowingCanvas: true,
      isTerminalFocusSuspended: true,
      focusTarget: target,
      currentFocusedWorktreeID: "/tmp/repo/wt-2",
      currentFocusedTabID: TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000306")!)
    )

    #expect(result == nil)
  }
}
