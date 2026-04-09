import Foundation
import Testing

@testable import supacode

struct WorktreeTerminalStateTests {
  @Test func resolveInheritancePrefersExplicitSurface() {
    let explicit = UUID()
    let focused = UUID()

    let resolved = WorktreeTerminalState.resolveInheritanceSurfaceID(
      inheritingFromSurfaceId: explicit,
      focusedSurfaceId: focused,
      inheritFromFocusedSurface: false
    )

    #expect(resolved == explicit)
  }

  @Test func resolveInheritanceUsesFocusedSurfaceWhenEnabled() {
    let focused = UUID()

    let resolved = WorktreeTerminalState.resolveInheritanceSurfaceID(
      inheritingFromSurfaceId: nil,
      focusedSurfaceId: focused,
      inheritFromFocusedSurface: true
    )

    #expect(resolved == focused)
  }

  @Test func resolveInheritanceIgnoresFocusedSurfaceWhenDisabled() {
    let focused = UUID()

    let resolved = WorktreeTerminalState.resolveInheritanceSurfaceID(
      inheritingFromSurfaceId: nil,
      focusedSurfaceId: focused,
      inheritFromFocusedSurface: false
    )

    #expect(resolved == nil)
  }

  @Test func preferredRevealInFinderPathPrefersRuntimePWD() {
    let path = WorktreeTerminalState.preferredRevealInFinderPath(
      runtimePWD: " /tmp/repo/wt/deep \n",
      inheritedWorkingDirectory: "/tmp/repo/wt",
      worktreeDirectory: "/tmp/repo"
    )

    #expect(path == "/tmp/repo/wt/deep")
  }

  @Test func preferredRevealInFinderPathFallsBackToInheritedWorkingDirectory() {
    let path = WorktreeTerminalState.preferredRevealInFinderPath(
      runtimePWD: " \n ",
      inheritedWorkingDirectory: "/tmp/repo/wt",
      worktreeDirectory: "/tmp/repo"
    )

    #expect(path == "/tmp/repo/wt")
  }

  @Test func preferredRevealInFinderPathFallsBackToWorktreeDirectory() {
    let path = WorktreeTerminalState.preferredRevealInFinderPath(
      runtimePWD: nil,
      inheritedWorkingDirectory: nil,
      worktreeDirectory: "/tmp/repo"
    )

    #expect(path == "/tmp/repo")
  }
}
