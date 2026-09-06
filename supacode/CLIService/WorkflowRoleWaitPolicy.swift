import Foundation
import ProwlCLIShared

// supacode/CLIService/WorkflowRoleWaitPolicy.swift
// The pure decision core of a `message` step's idle wait (docs-ai 063 B3, dsl-spec §10): the
// #733 evidence rules without their five-second cap, evaluated against the baseline captured
// when the wait started so a fresh exact `turn-ended` ends the wait even while the screen
// detector still shows `working`. Exact `needs-input` wins over every idle path.

@MainActor
struct WorkflowRoleWaitPolicy {
  /// How long a heuristic `blocked` must persist before the wait ends as blocked.
  let blockedGraceMilliseconds: Int
  /// How long a live pane may show no detected agent before the wait gives up.
  let appearanceGraceMilliseconds: Int

  private var baseline: AgentConditionEvidence.Baseline?
  private var stabilizer = AgentConditionEvidence.HeuristicStabilizer()
  private var blockedSinceMilliseconds: Int?

  init(blockedGraceMilliseconds: Int = 30_000, appearanceGraceMilliseconds: Int = 10_000) {
    self.blockedGraceMilliseconds = blockedGraceMilliseconds
    self.appearanceGraceMilliseconds = appearanceGraceMilliseconds
  }

  /// One poll; nil keeps waiting.
  mutating func observe(
    _ snapshot: AgentConditionSnapshot, pendingDispatchID: String?, elapsedMilliseconds: Int
  ) -> WorkflowRoleWaitOutcome? {
    guard snapshot.isLive else { return .gone }
    if let pendingDispatchID { return .dispatchPending(pendingDispatchID) }
    if baseline == nil {
      baseline = AgentConditionEvidence.Baseline(snapshot: snapshot)
    }
    guard let baseline, snapshot.agent != nil else {
      return elapsedMilliseconds >= appearanceGraceMilliseconds ? .noAgent : nil
    }
    let state = AgentConditionEvidence.normalizedState(snapshot)
    // An exact `needs-input` outranks every idle path: the agent is asking, not listening.
    if AgentConditionEvidence.exactMatch(
      condition: .blocked, snapshot: snapshot, normalizedState: state, baseline: baseline, minimumConfidence: .auto)
      != nil
    {
      return .blocked
    }
    switch AgentConditionEvidence.idleVerdict(for: snapshot, baseline: baseline) {
    case .idle:
      return .idle
    case .settling(let state):
      blockedSinceMilliseconds = nil
      let detectorCandidate =
        AgentConditionEvidence.detectorReports(.idle, normalizedState: state)
        && AgentConditionEvidence.allowsHeuristic(.auto, condition: .idle, snapshot: snapshot)
      return stabilizer.observe(candidate: detectorCandidate ? state : nil, elapsedMilliseconds: elapsedMilliseconds)
        ? .idle : nil
    case .busy(let state):
      _ = stabilizer.observe(candidate: nil, elapsedMilliseconds: elapsedMilliseconds)
      guard AgentConditionEvidence.detectorReports(.blocked, normalizedState: state) else {
        blockedSinceMilliseconds = nil
        return nil
      }
      let since = blockedSinceMilliseconds ?? elapsedMilliseconds
      blockedSinceMilliseconds = since
      return elapsedMilliseconds - since >= blockedGraceMilliseconds ? .blocked : nil
    }
  }
}
