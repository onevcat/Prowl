import Testing

@testable import Prowl

struct WorktreeRowActivityIndicatorTests {
  @Test func idleRowShowsNothing() {
    #expect(resolve(taskStatus: .idle) == .none)
    #expect(resolve(taskStatus: nil) == .none)
  }

  @Test func rowWorkKeepsThePlainProgressIndicator() {
    #expect(resolve(isLoading: true) == .progress)
    #expect(resolve(isLoading: true, taskStatus: .running, hasBusyAgent: true) == .progress)
    #expect(resolve(isLoading: true, hasBlockedAgent: true) == .progress)
  }

  @Test func blockedAgentWinsOverWork() {
    #expect(resolve(taskStatus: .running, hasBlockedAgent: true, hasBusyAgent: true) == .blocked)
  }

  @Test func workingAgentShowsTheBagua() {
    #expect(resolve(taskStatus: .running, hasBusyAgent: true) == .agentWorking)
  }

  @Test func commandWithoutAnAgentKeepsThePlainProgressIndicator() {
    #expect(resolve(taskStatus: .running, hasBusyAgent: false) == .progress)
  }

  @Test func reduceMotionKeepsThePlainProgressIndicator() {
    #expect(resolve(taskStatus: .running, hasBusyAgent: true, reduceMotion: true) == .progress)
  }

  private func resolve(
    isLoading: Bool = false,
    taskStatus: WorktreeTaskStatus? = nil,
    hasBlockedAgent: Bool = false,
    hasBusyAgent: Bool = false,
    reduceMotion: Bool = false
  ) -> WorktreeRowActivityIndicator {
    WorktreeRowActivityIndicator(
      isLoading: isLoading,
      taskStatus: taskStatus,
      hasBlockedAgent: hasBlockedAgent,
      hasBusyAgent: hasBusyAgent,
      reduceMotion: reduceMotion
    )
  }
}
