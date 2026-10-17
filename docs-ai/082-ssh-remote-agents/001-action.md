# 082 — SSH Remote Agents: Action Log

The outcome of [000-plan.md](000-plan.md), slice by slice. Each row names the PR; the
sections below record what shipped and what differs from the plan.

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-17 | S1: typed process references (C2) and the `ConnectionKey` value type; local-only OS entry points; evidence retirement on an origin change. No behaviour change for local panes | S1 PR |

## S1 — Typed process references

- **Types** (`App/Sources/Domain/AgentDetection/ProcessRef.swift`). `ProcessRef` is
  `.local(pid)` or `.remote(RemoteProcessRef)`; `RemoteProcessRef` is connection key, boot
  id, pid and native start token, and its equality is generation equality.
  `LocalProcessGeneration` (pid + libproc start time) is the old `AgentProcessGeneration`
  struct; `AgentProcessGeneration` is now `.local(LocalProcessGeneration)` or
  `.remote(RemoteProcessRef)`. `ConnectionKey` carries user, hostname, port, jump chain and
  the `-F` file; its resolution lands in S2.
- **Where the reference replaced a pid.** `ForegroundProcess.ref` (the parent stays a
  namespace pid for walks inside one job), `ForegroundJob.launchProcess(of:)`,
  `IdentifiedAgentProcess.launchProcess`, `PaneAgentState.agentProcess` and `launchProcess`,
  and the coordinator's bound generation.
- **Local-only entry points.** `AgentSessionResolver` takes `LocalAgentProcess` (agent and
  local pid), produced only by `IdentifiedAgentProcess.local`. `CodexLogProvider`,
  `ClaudeRuntimeProvider`, `ClaudeRuntimeDecoder`, the hook observation store and CLI caller
  ancestry take `LocalProcessGeneration`. `processIsLiveAncestor` over references returns
  false for any remote pair. `currentAgentEvidence` and the `agents read` snapshot path
  read only local references.
- **Retirement by owner.**
  - Session and launch observation retire when the identified reference changes; a
    remote reference never equals a local one, so an origin change retires them.
  - The launch process survives an engine replacement while it stays a live ancestor; a
    launch on another origin is never an ancestor.
  - The coordinator rebinds on any origin change, for every agent. It creates providers only
    for a local generation, and a remote generation has no OSC fence yet (S3 adds it), so
    no record counts for it.
  - Profile launch context: a Profile launch runs on this Mac, so an agent whose launch is
    remote drops the pane's Profile name and config root.
  - Managed hooks: when the pane's agent is remote, the local managed hook is revoked and
    the evidence epoch rotates.
  - OSC records: the surface keeps the origin of its last identified agent and the
    moment that origin replaced another one, as long as its record store
    (`programStatusOriginBySurface`). The coordinator fence is the later of the
    generation's start and that moment, so records that arrived on a departed origin never
    decide for the returning agent, even after the coordinator is rebuilt (review round 1).
    The change is timestamped when the probe that saw it returns, so reports that landed
    while that probe ran are left out too (review round 2); the screen decides until the
    next report.
