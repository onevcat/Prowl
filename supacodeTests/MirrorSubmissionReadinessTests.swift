import Foundation
import Testing

@testable import supacode

struct MirrorSubmissionReadinessTests {
  private let generation = UUID()

  private func observation(
    generation: UUID? = nil, revision: UInt64 = 1, screen: String = "empty",
    edit: TimeInterval? = nil, refusal: String? = nil
  ) -> MirrorSubmissionReadiness.Observation {
    .init(
      generation: generation ?? self.generation, runtimeRevision: revision,
      screenDigest: Data(screen.utf8), lastEditingAt: edit, refusal: refusal)
  }

  @Test func newEditsAndScreenChangesInvalidateAdvertisedReadiness() {
    var gate = MirrorSubmissionReadiness()
    #expect(!gate.observe(observation(), now: 0).canSubmit)
    let ready = gate.observe(observation(), now: 2)
    #expect(ready.canSubmit)
    #expect(gate.observe(observation(), now: 3).revision == ready.revision)
    #expect(!gate.observe(observation(edit: 3), now: 3).canSubmit)
    let claimAfterEdit = gate.claim(ready)
    #expect(!claimAfterEdit)
    let editedReady = gate.observe(observation(edit: 3), now: 5)
    #expect(editedReady.canSubmit)
    #expect(!gate.observe(observation(screen: "draft", edit: 3), now: 5).canSubmit)
    let claimAfterScreenChange = gate.claim(editedReady)
    #expect(!claimAfterScreenChange)
  }

  @Test func claimedInputWaitsForRuntimeEvidenceEvenIfScreenChanges() {
    var gate = MirrorSubmissionReadiness()
    _ = gate.observe(observation(), now: 0)
    let ready = gate.observe(observation(), now: 2)
    let claimed = gate.claim(ready)
    #expect(claimed)
    let replayed = gate.claim(ready)
    #expect(!replayed)
    _ = gate.observe(observation(screen: "new pixels"), now: 3)
    #expect(!gate.observe(observation(screen: "new pixels"), now: 30).canSubmit)
    _ = gate.observe(observation(revision: 2), now: 31)
    #expect(gate.observe(observation(revision: 2), now: 33).canSubmit)
  }

  @Test func processReplacementAndRefusalCannotUseOldState() {
    var gate = MirrorSubmissionReadiness()
    _ = gate.observe(observation(), now: 0)
    let ready = gate.observe(observation(), now: 2)
    let replacement = observation(generation: UUID())
    #expect(!gate.observe(replacement, now: 3).canSubmit)
    let oldProcessClaim = gate.claim(ready)
    #expect(!oldProcessClaim)
    #expect(gate.observe(replacement, now: 5).canSubmit)
    #expect(!gate.observe(observation(refusal: "Agent is working."), now: 6).canSubmit)
    #expect(!gate.observe(observation(refusal: "Agent is working."), now: 600).canSubmit)
  }

  @Test func invalidOrRegressingTimeRevokesReadiness() {
    var gate = MirrorSubmissionReadiness()
    _ = gate.observe(observation(), now: 10)
    let ready = gate.observe(observation(), now: 12)
    #expect(!gate.observe(observation(), now: .nan).canSubmit)
    let invalidTimeClaim = gate.claim(ready)
    #expect(!invalidTimeClaim)
    _ = gate.observe(observation(), now: 20)
    let next = gate.observe(observation(), now: 22)
    #expect(!gate.observe(observation(), now: 19).canSubmit)
    let regressingTimeClaim = gate.claim(next)
    #expect(!regressingTimeClaim)
  }
}
