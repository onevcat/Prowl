import Foundation

/// Known agent install/launcher binary names (lowercased). Aliases map to the
/// same agent; extend this table when onboarding a new CLI.
private let knownAgentBinaries: [String: DetectedAgent] = [
  "pi": .pi,
  "omp": .omp, "oh-my-pi": .omp,
  "claude": .claude, "claude-code": .claude,
  "codex": .codex, "omx": .codex, "oh-my-codex": .codex,
  "gemini": .gemini,
  "cursor": .cursor, "cursor-agent": .cursor,
  "cline": .cline,
  "opencode": .opencode, "open-code": .opencode,
  "copilot": .copilot, "github-copilot": .copilot, "ghcs": .copilot,
  "kimi": .kimi, "kimi code": .kimi,
  "droid": .droid,
  "amp": .amp, "amp-local": .amp,
  "qodercli": .qoder,
  "qwen": .qwen,
  "grok": .grok,
]

func identifyAgent(processName: String) -> DetectedAgent? {
  let lower = processName.lowercased()
  if let agent = knownAgentBinaries[lower] {
    return agent
  }
  // Versioned install binary only, e.g. `grok-0.2.101-macos-aarch64`.
  // Must not match model-id tokens like `grok-4` / `grok-4.5` that show up
  // as argv fragments of other agents (score-40 wrapped-runtime candidates).
  if isGrokVersionedBinaryName(lower) {
    return .grok
  }
  return nil
}

/// Install packages are named `grok-<semver>-<platform>-<arch>` (verified
/// against `~/.grok/downloads/grok-0.2.101-macos-aarch64`). Model ids
/// (`grok-4`, `grok-4.5`) never include a platform segment.
private func isGrokVersionedBinaryName(_ lower: String) -> Bool {
  guard lower.hasPrefix("grok-") else { return false }
  return lower.contains("-macos-")
    || lower.contains("-linux-")
    || lower.contains("-windows-")
}

struct IdentifiedAgentProcess: Equatable, Sendable {
  let agent: DetectedAgent
  let name: String
  let process: ForegroundProcess
  /// The process the shell launched for this agent (`ForegroundJob.launchProcessID(of:)`).
  /// `process` is what state and sessions are read from; this is what a launch is
  /// identified by, so an engine child taking over `process` is not a replacement.
  let launchProcessID: pid_t

  init(agent: DetectedAgent, name: String, process: ForegroundProcess, launchProcessID: pid_t? = nil) {
    self.agent = agent
    self.name = name
    self.process = process
    self.launchProcessID = launchProcessID ?? process.pid
  }

  /// Icon token for `CommandIconMap`. The shared `agent` entrypoint name maps
  /// to the Cursor icon there, so alias-identified agents resolve through the
  /// detected agent instead of the raw process name.
  var iconLookupToken: String {
    name == "agent" ? agent.iconLookupToken : name
  }
}

func identifyAgentInJob(_ job: ForegroundJob) -> IdentifiedAgentProcess? {
  var best: AgentCandidate?

  for process in job.processes {
    for candidate in agentCandidates(for: process) {
      guard let agent = identifyAgent(candidate: candidate, process: process) else { continue }
      if best == nil || candidate.score > best!.score {
        best = AgentCandidate(score: candidate.score, agent: agent, name: candidate.name, process: process)
      }
    }
  }

  return best.map {
    IdentifiedAgentProcess(
      agent: $0.agent,
      name: $0.name,
      process: $0.process,
      launchProcessID: job.launchProcessID(of: $0.process.pid)
    )
  }
}

private func agentCandidates(for process: ForegroundProcess) -> [(name: String, score: Int)] {
  var candidates: [(String, Int)] = []

  if let argv0 = process.argv0, let name = normalizedProcessName(argv0) {
    candidates.append((name, 80))
  }
  if let name = normalizedProcessName(process.name) {
    candidates.append((name, 70))
  }

  let primaryName = normalizedProcessName(process.argv0 ?? process.name) ?? process.name.lowercased()
  if isWrappedRuntime(primaryName), let cmdline = process.cmdline {
    for token in cmdline.split(whereSeparator: \.isWhitespace) {
      guard let name = normalizedProcessName(String(token)) else { continue }
      candidates.append((name, 40))
    }
  }

  return candidates
}

private func identifyAgent(candidate: (name: String, score: Int), process: ForegroundProcess) -> DetectedAgent? {
  if candidate.name == "agent" {
    // Cursor and Grok Build both ship an `agent` entrypoint. Disambiguate from
    // path/cmdline evidence only — bare `agent` stays unknown.
    if isCursorAgentAlias(process) {
      return .cursor
    }
    if isGrokAgentAlias(process) {
      return .grok
    }
    return nil
  }
  // Grok Build is a direct Mach-O executable, never a wrapped-runtime script.
  // A bare `grok` cmdline token is a model argument (`node app.js --model
  // grok`), not the agent — only argv0/name evidence may identify it.
  if candidate.name == "grok", candidate.score == 40 {
    return nil
  }
  return identifyAgent(processName: candidate.name)
}

private func isCursorAgentAlias(_ process: ForegroundProcess) -> Bool {
  let haystack = agentAliasHaystack(process)
  return haystack.contains("cursor-agent")
    || haystack.contains("cursor.app")
}

private func isGrokAgentAlias(_ process: ForegroundProcess) -> Bool {
  // Production `argv0` is basename-only (`ProcessDetection` strips the path);
  // the full executable path is the first whitespace token of `cmdline`.
  // Only inspect those two executable locations — never later argv tokens
  // (e.g. `agent --model grok-4` must stay unknown).
  let executablePaths = [
    process.argv0,
    process.cmdline?.split(whereSeparator: \.isWhitespace).first.map(String.init),
  ]
  .compactMap { $0?.lowercased() }

  for path in executablePaths {
    if path.contains("/.grok/") {
      return true
    }
    if let basename = ProcessDetection.basename(path), isGrokVersionedBinaryName(basename) {
      return true
    }
  }
  return false
}

private func agentAliasHaystack(_ process: ForegroundProcess) -> String {
  [
    process.argv0,
    process.cmdline,
  ]
  .compactMap(\.self)
  .joined(separator: " ")
  .lowercased()
}

private struct AgentCandidate {
  let score: Int
  let agent: DetectedAgent
  let name: String
  let process: ForegroundProcess
}

private func normalizedProcessName(_ raw: String) -> String? {
  guard let basename = ProcessDetection.basename(raw) else { return nil }
  let lower = basename.lowercased()
  if lower.hasSuffix(".js") {
    return String(lower.dropLast(3))
  }
  return lower
}

private func isWrappedRuntime(_ name: String) -> Bool {
  [
    "node", "bun", "python", "python3", "ruby", "deno",
    "sh", "bash", "zsh", "fish", "tmux", "npx", "bunx",
  ].contains(name)
}
