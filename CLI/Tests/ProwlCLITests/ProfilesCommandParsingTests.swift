import XCTest

@testable import prowl

final class ProfilesCommandParsingTests: XCTestCase {
  func testListParsesAsTheProfilesLeaf() throws {
    _ = try ProfilesListCommand.parse(["--json"])
  }

  func testRootRoutesProfilesListToTheListLeaf() throws {
    let command = try ProwlCommand.parseAsRoot(["profiles", "list"])

    XCTAssertTrue(command is ProfilesListCommand)
  }
}
