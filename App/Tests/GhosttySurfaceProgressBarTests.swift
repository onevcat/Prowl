import Testing

@testable import supacode

struct GhosttySurfaceProgressBarTests {
  @Test func zeroPassesThrough() {
    #expect(GhosttySurfaceProgressBar.bucketedPercent(0) == 0)
  }

  @Test func terminusPassesThrough() {
    #expect(GhosttySurfaceProgressBar.bucketedPercent(100) == 100)
    #expect(GhosttySurfaceProgressBar.bucketedPercent(150) == 100)
  }

  @Test func midValuesQuantizeDownToFivePercentSteps() {
    #expect(GhosttySurfaceProgressBar.bucketedPercent(1) == 0)
    #expect(GhosttySurfaceProgressBar.bucketedPercent(4) == 0)
    #expect(GhosttySurfaceProgressBar.bucketedPercent(5) == 5)
    #expect(GhosttySurfaceProgressBar.bucketedPercent(7) == 5)
    #expect(GhosttySurfaceProgressBar.bucketedPercent(47) == 45)
    #expect(GhosttySurfaceProgressBar.bucketedPercent(99) == 95)
  }

  @Test func collapsesASweepToAtMostTwentyOneDistinctValues() {
    let distinct = Set((0...100).map(GhosttySurfaceProgressBar.bucketedPercent))
    // 0, 5, 10, ..., 95, 100 -> 21 buckets.
    #expect(distinct.count == 21)
  }
}
