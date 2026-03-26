import Testing

@testable import supacode

struct CanvasCurrentDirectoryFormatterTests {
  @Test func returnsNilForNilOrWhitespacePath() {
    #expect(CanvasCurrentDirectoryFormatter.displayPath(for: nil, homePath: "/Users/test") == nil)
    #expect(CanvasCurrentDirectoryFormatter.displayPath(for: "   ", homePath: "/Users/test") == nil)
  }

  @Test func collapsesHomeDirectoryPrefix() {
    #expect(
      CanvasCurrentDirectoryFormatter.displayPath(
        for: "/Users/test/project/src",
        homePath: "/Users/test"
      ) == "~/project/src"
    )
    #expect(
      CanvasCurrentDirectoryFormatter.displayPath(
        for: "/Users/test",
        homePath: "/Users/test"
      ) == "~"
    )
  }

  @Test func keepsNonHomeAbsolutePath() {
    #expect(
      CanvasCurrentDirectoryFormatter.displayPath(
        for: "/tmp/project",
        homePath: "/Users/test"
      ) == "/tmp/project"
    )
  }

  @Test func trimsTrailingSlashForNonRootPath() {
    #expect(
      CanvasCurrentDirectoryFormatter.displayPath(
        for: "/Users/test/project/",
        homePath: "/Users/test"
      ) == "~/project"
    )
    #expect(
      CanvasCurrentDirectoryFormatter.displayPath(
        for: "/",
        homePath: "/Users/test"
      ) == "/"
    )
  }

  @Test func formatterOutputIsStableForShorteningServiceInputContract() {
    #expect(
      CanvasCurrentDirectoryFormatter.displayPath(
        for: "/Users/test/workspace/project/",
        homePath: "/Users/test"
      ) == "~/workspace/project"
    )
    #expect(
      CanvasCurrentDirectoryFormatter.displayPath(
        for: "/tmp/workspace/project/",
        homePath: "/Users/test"
      ) == "/tmp/workspace/project"
    )
  }

  @Test func detectsDuplicateDirectoryTitleFromAbsolutePath() {
    #expect(
      CanvasCurrentDirectoryFormatter.isDuplicateDirectoryTitle(
        "/Users/test/project",
        currentDirectoryPath: "/Users/test/project",
        homePath: "/Users/test"
      )
    )
  }

  @Test func detectsDuplicateDirectoryTitleFromDisplayPath() {
    #expect(
      CanvasCurrentDirectoryFormatter.isDuplicateDirectoryTitle(
        "~/project/src",
        currentDirectoryPath: "/Users/test/project/src",
        homePath: "/Users/test"
      )
    )
  }

  @Test func doesNotTreatCommandTitleAsDuplicateDirectory() {
    #expect(
      CanvasCurrentDirectoryFormatter.isDuplicateDirectoryTitle(
        "npm test",
        currentDirectoryPath: "/Users/test/project",
        homePath: "/Users/test"
      ) == false
    )
  }
}
