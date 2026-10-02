import Foundation
import Testing

@testable import supacode

struct AgentDetectionScheduleTests {
  @Test func coldSurfacesDoNotScheduleDetection() {
    let now = Date(timeIntervalSince1970: 100)
    let schedule = AgentDetectionSchedule.cold

    #expect(schedule.nextInterval(now: now) == nil)
  }

  @Test func userActivityWarmsAColdSurfaceForAShortWindow() {
    let now = Date(timeIntervalSince1970: 100)
    let schedule = AgentDetectionSchedule.cold.warmed(now: now)

    #expect(schedule.nextInterval(now: now) == .seconds(2))
    #expect(schedule.nextInterval(now: now.addingTimeInterval(29.9)) == .seconds(2))
    #expect(schedule.nextInterval(now: now.addingTimeInterval(30.1)) == nil)
  }

  @Test func warmingExtendsTheWindow() {
    let now = Date(timeIntervalSince1970: 100)
    let first = AgentDetectionSchedule.cold.warmed(now: now)
    let extended = first.warmed(now: now.addingTimeInterval(20))

    #expect(extended.nextInterval(now: now.addingTimeInterval(49.9)) == .seconds(2))
    #expect(extended.nextInterval(now: now.addingTimeInterval(50.1)) == nil)
  }

  @Test func detectedAgentKeepsActiveDetectionUntilItDisappears() {
    let now = Date(timeIntervalSince1970: 100)
    let active = AgentDetectionSchedule.cold.warmed(now: now).observedAgent(now: now)

    #expect(active.nextInterval(now: now.addingTimeInterval(120)) == .milliseconds(300))

    let cooldown = active.observedNoAgent(now: now.addingTimeInterval(120))
    #expect(cooldown.nextInterval(now: now.addingTimeInterval(149.9)) == .seconds(2))
    #expect(cooldown.nextInterval(now: now.addingTimeInterval(150.1)) == nil)
  }
}
