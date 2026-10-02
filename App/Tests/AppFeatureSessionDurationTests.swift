import Foundation
import Testing

@testable import supacode

struct AppFeatureSessionDurationTests {
  @Test func returnsNilWhenLaunchedAtIsNil() {
    #expect(AppFeature.sessionDurationSeconds(launchedAt: nil, now: Date()) == nil)
  }

  @Test func returnsElapsedSecondsAsInteger() {
    let start = Date(timeIntervalSince1970: 1_000)
    let later = Date(timeIntervalSince1970: 1_042)
    #expect(AppFeature.sessionDurationSeconds(launchedAt: start, now: later) == 42)
  }

  @Test func clampsNegativeDurationsToZero() {
    let future = Date(timeIntervalSince1970: 2_000)
    let past = Date(timeIntervalSince1970: 1_000)
    #expect(AppFeature.sessionDurationSeconds(launchedAt: future, now: past) == 0)
  }

  @Test func truncatesFractionalSeconds() {
    let start = Date(timeIntervalSince1970: 1_000)
    let later = Date(timeIntervalSince1970: 1_000.999)
    #expect(AppFeature.sessionDurationSeconds(launchedAt: start, now: later) == 0)
  }
}
