# 067.009 — Interactive mobile input without task receipts

Status: Implemented (2026-10-01).

## Context

Mobile text mirrors route ordinary human messages through agents.dispatch. A failed
Agent completion command leaves a pending task that blocks every later message even
when the Agent is idle. Mac keyboard input has no such task-completion requirement.

## Design

Add agentsInput to the structured command wire and advertise agent-input. Reuse the
Agent dispatch readiness and guarded delivery code, but deliver the exact human text
without creating, completing, abandoning or inspecting a dispatch. Existing automation
receipts remain unchanged. This is explicit human interaction, like local keyboard input;
it does not certify or cancel an automation task. A per-pane in-flight guard prevents
interactive and automated deliveries racing while readiness is awaited.

Keep text-v1, authenticated pane leases, cancellation, bounded request-ID deduplication,
and delivery-receipt recovery. Missing capability requires upgrading Host; never fall
back to dispatch. iOS and Android acknowledge bytes plus Enter, not Agent completion.
Shell submission remains unavailable. Profile launch prompts still use their existing
launch contract; subsequent interactive messages do not create further dispatches.

## Alternatives and result

Completing or abandoning the old dispatch from the phone would falsely assert a task
outcome. Relaxing automation gating would change the workflow contract for unrelated
callers. A separate interactive command preserves both contracts without switching
mobile clients to a terminal protocol.

Host dispatch/Mirror tests, including real Ghostty terminal integration, passed.
iOS simulator tests (48) and Android unit tests (25 passed, one external native TLS
fixture skipped), lint and Debug build passed. CLI smoke and 106 integration tests passed. The final CLI unit run passed 300
tests, including the new wire round trip; two unchanged WorkflowHistoryRetentionTests
export cases failed with exportFailed, also on an isolated rerun. macOS Debug built and signature verified.
Changed Host Swift files passed strict lint; the full check remains blocked by five
pre-existing legacy_swiftui_aspect_ratio violations in RepositoryIconImage.swift.

Physical-device reconnect/background acceptance remains to be checked. Mobile clients
were not installed as part of this change.
