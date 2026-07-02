import Foundation
import Testing

@testable import supacode

struct CanvasViewTitlePipelineTests {
  @Test func canvasDirectoryFallbackUsesWorktreeDirectoryWhenReportedPathIsMissing() {
    #expect(
      canvasCurrentDirectoryPath(
        reportedPath: nil,
        fallbackWorktreeDirectory: "/Users/yam/Developer/TikTok2"
      ) == "/Users/yam/Developer/TikTok2"
    )
    #expect(
      canvasCurrentDirectoryPath(
        reportedPath: "  ",
        fallbackWorktreeDirectory: "/Users/yam/Developer/TikTok2"
      ) == "/Users/yam/Developer/TikTok2"
    )
  }

  @Test func canvasPipelineAppliesShortenedDirectoryAndPreservesSegment3Source() {
    let homePath = NSHomeDirectory()
    let segments = canvasCardTitleSegments(
      currentDirectoryPath: "\(homePath)/project/src",
      tabTitle: "feature/super-long-title",
      fallbackWorktreeName: "feature/fallback",
      cachedDirectoryEntry: CanvasDirectoryDisplayCacheEntry(
        normalizedDisplayPath: "~/project/src",
        shortenedDisplayPath: "~/pr/src"
      )
    )

    #expect(segments.currentDirectory == "~/pr/src")
    #expect(segments.worktreeName == "feature/super-long-title")
  }

  @Test func duplicateDirectoryTitleStillOmitsSegment3AfterShorteningPipeline() {
    let homePath = NSHomeDirectory()
    let segments = canvasCardTitleSegments(
      currentDirectoryPath: "\(homePath)/project/src",
      tabTitle: "~/project/src",
      cachedDirectoryEntry: CanvasDirectoryDisplayCacheEntry(
        normalizedDisplayPath: "~/project/src",
        shortenedDisplayPath: "~/pr/src"
      )
    )

    #expect(segments.currentDirectory == "~/pr/src")
    #expect(segments.worktreeName == nil)
  }

  @Test func localHostnameTitleFallsBackToWorktreeName() {
    let segments = canvasCardTitleSegments(
      currentDirectoryPath: "/Users/yam/Developer/Prowl",
      tabTitle: "Yams-MacBook-Pro.local",
      fallbackWorktreeName: "custom",
      cachedDirectoryEntry: nil
    )

    #expect(segments.worktreeName == "custom")
  }

  @Test func cloudHostnameTitleFallsBackToWorktreeName() {
    let segments = canvasCardTitleSegments(
      currentDirectoryPath: "/Users/yam/Developer/Warlock",
      tabTitle: "ip-192-168-31-248.ap-southeast-1.compute.internal",
      fallbackWorktreeName: "feature/warlock",
      cachedDirectoryEntry: nil
    )

    #expect(segments.worktreeName == "feature/warlock")
  }

  @Test func staleAsyncResultIsIgnoredWhenTokenIsOutdated() {
    var tokens: [TerminalTabID: CanvasDirectoryShorteningCoordinator.Token] = [:]
    let tabID = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    let stale = CanvasDirectoryShorteningCoordinator.nextToken(for: tabID, tokens: &tokens)
    let latest = CanvasDirectoryShorteningCoordinator.nextToken(for: tabID, tokens: &tokens)

    #expect(CanvasDirectoryShorteningCoordinator.shouldApply(token: stale, for: tabID, latestTokens: tokens) == false)
    #expect(CanvasDirectoryShorteningCoordinator.shouldApply(token: latest, for: tabID, latestTokens: tokens))
  }
}
