import Foundation
import Testing

@testable import supacode

struct GhosttyRuntimeTerminalProgramTests {
  /// `TERM_PROGRAM` reports Prowl with its version (upstream #440).
  @Test func terminalProgramOverridesIdentifyProwl() {
    let overrides = GhosttyRuntime.terminalProgramOverrides(version: "2026.7.6")
    #expect(overrides.contains("env = TERM_PROGRAM=prowl"))
    #expect(overrides.contains("env = TERM_PROGRAM_VERSION=2026.7.6"))
  }

  /// A missing or blank version still emits a placeholder, never Ghostty's.
  @Test func terminalProgramOverridesFallBackWhenVersionUnavailable() {
    for version: String? in [nil, "", "   "] {
      let overrides = GhosttyRuntime.terminalProgramOverrides(version: version)
      #expect(overrides.contains("env = TERM_PROGRAM=prowl"))
      #expect(overrides.contains("env = TERM_PROGRAM_VERSION=unknown"))
    }
  }

  /// Surrounding whitespace is trimmed from the emitted version.
  @Test func terminalProgramOverridesTrimVersionWhitespace() {
    let overrides = GhosttyRuntime.terminalProgramOverrides(version: " 2026.7.6 ")
    #expect(overrides.contains("env = TERM_PROGRAM_VERSION=2026.7.6"))
  }

  @Test func terminalProgramOverridesAreKeyValueDirectives() {
    let lines = GhosttyRuntime.terminalProgramOverrides(version: "9.9.9")
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    #expect(!lines.isEmpty)
    for line in lines {
      #expect(line.contains("="), "Override line missing `=`: \(line)")
    }
  }
}
