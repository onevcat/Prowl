// supacodeTests/CLITargetSelectorTests.swift
// Tests for TargetSelector mutual exclusivity and encoding.

import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct CLITargetSelectorTests {

  // MARK: - Encoding stability

  @Test func selectorNoneRoundTrips() throws {
    let selector = TargetSelector.none
    let data = try JSONEncoder().encode(selector)
    let decoded = try JSONDecoder().decode(TargetSelector.self, from: data)
    #expect(decoded == .none)
  }

  @Test func selectorWorktreeRoundTrips() throws {
    let selector = TargetSelector.worktree("my-project")
    let data = try JSONEncoder().encode(selector)
    let decoded = try JSONDecoder().decode(TargetSelector.self, from: data)
    #expect(decoded == .worktree("my-project"))
  }

  @Test func selectorTabRoundTrips() throws {
    let selector = TargetSelector.tab("tab-uuid-123")
    let data = try JSONEncoder().encode(selector)
    let decoded = try JSONDecoder().decode(TargetSelector.self, from: data)
    #expect(decoded == .tab("tab-uuid-123"))
  }

  @Test func selectorPaneRoundTrips() throws {
    let selector = TargetSelector.pane("pane-0")
    let data = try JSONEncoder().encode(selector)
    let decoded = try JSONDecoder().decode(TargetSelector.self, from: data)
    #expect(decoded == .pane("pane-0"))
  }

  // MARK: - Equality

  @Test func differentSelectorsAreNotEqual() {
    #expect(TargetSelector.worktree("a") != TargetSelector.tab("a"))
    #expect(TargetSelector.tab("a") != TargetSelector.pane("a"))
    #expect(TargetSelector.none != TargetSelector.worktree(""))
  }

  @Test func sameSelectorsAreEqual() {
    #expect(TargetSelector.worktree("x") == TargetSelector.worktree("x"))
    #expect(TargetSelector.none == TargetSelector.none)
  }
}
