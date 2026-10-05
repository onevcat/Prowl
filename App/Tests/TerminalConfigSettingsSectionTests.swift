import Foundation
import Testing

@testable import Prowl

@MainActor
struct TerminalConfigSettingsSectionTests {
  @Test func displayPathAbbreviatesTheHomeFolder() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    let prefix = home.hasSuffix("/") ? home : home + "/"
    #expect(
      TerminalConfigSettingsSection.displayPath(prefix + ".config/prowl/ghostty.conf") == "~/.config/prowl/ghostty.conf"
    )
    #expect(TerminalConfigSettingsSection.displayPath("/etc/ghostty.conf") == "/etc/ghostty.conf")
    let sibling = String(prefix.dropLast()) + "-other/ghostty.conf"
    #expect(TerminalConfigSettingsSection.displayPath(sibling) == sibling)
  }
}
