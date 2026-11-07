import Foundation

/// Known agent install/launcher binary names (lowercased). Aliases map to the
/// same agent; extend this table when onboarding a new CLI.
private nonisolated let knownAgentBinaries: [String: DetectedAgent] = [
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
  "devin": .devin,
  "droid": .droid,
  "amp": .amp, "amp-local": .amp,
  "qodercli": .qoder,
  "qwen": .qwen,
  "grok": .grok,
  // Bare `antigravity` stays unmapped: the Antigravity IDE ships an
  // `antigravity` launcher (and an `agy` shim) that opens the desktop app.
  "agy": .antigravity, "antigravity-cli": .antigravity, "antigravity_cli": .antigravity,
  // Bare `trae` stays unmapped: the Trae IDE ships a `trae` launcher that opens
  // the desktop app. The CLI installs `traecli` with `traex` as the real
  // executable and `trae-cli`/`trae-agent` shims.
  "traecli": .trae, "traex": .trae, "trae-cli": .trae, "trae-agent": .trae,
]

/// Launchers that run the agent outside the pane's foreground job.
///
/// Happy (`happy-coder`) starts the agent on a PTY of its own, in its own session
/// and process group, and proxies that TUI into the pane. The engine is therefore
/// never a *job* member — only Happy's own Node processes are — so a probe that
/// reads the job alone finds no agent and the pane gets no Active Agents entry.
///
/// The engine is still a reachable descendant of the launcher, though, so
/// `ProcessDetection` walks down from a launcher and hands those processes over as
/// `ForegroundJob.hosted`. Identification then works off the engine's own argv, the
/// same evidence it uses for a directly launched agent, which is why there is no
/// table of launcher subcommands here: whatever `happy codex`, `happy gemini`,
/// `happy acp <runner>`, or a restored `happy resume <id>` ends up starting names
/// itself, and a subcommand that starts nothing (`auth`, `doctor`, the background
/// `daemon`) has no descendant to find. Reaching the real pid is also what keeps
/// session names and process-scoped native state working for these panes.
nonisolated enum AgentLauncher {
  /// Whether `process` is a launcher whose agent runs outside the job.
  static func hostsAgentsOutsideJob(_ process: ForegroundProcess) -> Bool {
    guard let argv0 = process.argv0 else { return false }
    if isHappyEntrypoint(argv0) { return true }
    // Happy's bin shim re-executes the bundled entrypoint through Node, so the
    // script argument is what names it.
    guard isWrappedRuntime(normalizedProcessName(argv0) ?? argv0.lowercased()) else { return false }
    let arguments =
      process.arguments ?? process.cmdline?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
    // Position-locked to the script: the first non-flag argument after the runtime's
    // own flags, and only that one. A later token that merely says `happy` is a word
    // in a payload, so a runtime flag that swallowed its value can cost a detection
    // but never invent one.
    let script = arguments.dropFirst().first { !$0.hasPrefix("-") }
    return script.map(isHappyEntrypoint) ?? false
  }

  /// Happy's own entrypoint: its `happy` bin shim, the `happy.mjs` that shim points
  /// at, or the bundled `dist/index.mjs` it re-executes, under either the `happy` or
  /// the `happy-coder` package name.
  private static func isHappyEntrypoint(_ path: String) -> Bool {
    let name = normalizedProcessName(path)
    if name == "happy" || name == "happy.mjs" { return true }
    let lower = path.lowercased()
    return lower.contains("/node_modules/happy/") || lower.contains("/node_modules/happy-coder/")
  }
}

nonisolated func identifyAgent(processName: String) -> DetectedAgent? {
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
private nonisolated func isGrokVersionedBinaryName(_ lower: String) -> Bool {
  guard lower.hasPrefix("grok-") else { return false }
  return lower.contains("-macos-")
    || lower.contains("-linux-")
    || lower.contains("-windows-")
}

nonisolated struct IdentifiedAgentProcess: Equatable, Sendable {
  let agent: DetectedAgent
  let name: String
  let process: ForegroundProcess
  /// The process the shell launched for this agent (`ForegroundJob.launchProcess(of:)`).
  /// `process` is what state and sessions are read from; this is what a launch is
  /// identified by, so an engine child taking over `process` is not a replacement.
  let launchProcess: ProcessRef

  init(agent: DetectedAgent, name: String, process: ForegroundProcess, launchProcess: ProcessRef? = nil) {
    self.agent = agent
    self.name = name
    self.process = process
    self.launchProcess = launchProcess ?? process.ref
  }

  /// The local-only view for local OS readers; nil for a remote process.
  var local: LocalAgentProcess? {
    process.ref.localPID.map { LocalAgentProcess(agent: agent, pid: $0) }
  }

  /// Icon token for `CommandIconMap`. The shared `agent` entrypoint name maps
  /// to the Cursor icon there, so alias-identified agents resolve through the
  /// detected agent instead of the raw process name.
  var iconLookupToken: String {
    name == "agent" ? agent.iconLookupToken : name
  }
}

/// An identified agent process that runs on this Mac. Session resolution and other
/// readers of local OS state take this type, so a remote process cannot reach them.
struct LocalAgentProcess: Equatable, Sendable {
  let agent: DetectedAgent
  let pid: pid_t
}

nonisolated func identifyAgentInJob(_ job: ForegroundJob) -> IdentifiedAgentProcess? {
  // The job itself always decides first: an agent the shell started in the pane
  // outranks anything a launcher is hosting out of the job.
  let picked = bestAgentCandidate(in: job.processes) ?? hostedAgentCandidate(in: job.hosted)
  return picked.map {
    IdentifiedAgentProcess(
      agent: $0.agent,
      name: $0.name,
      process: $0.process,
      launchProcess: job.launchProcess(of: $0.process.ref)
    )
  }
}

/// Which command-line tokens of a wrapped runtime may name an agent.
private nonisolated enum TokenEvidence {
  /// Every whitespace-separated word of the command line. A pane's own job is the
  /// user's shell invocation, and an agent there can be named inside a single argv
  /// element: `sh -c "codex --model gpt-5"`, or the quoted command of
  /// `tmux new-session`. `isWrappedRuntime` lists `sh`, `zsh`, and `tmux` for exactly
  /// those shapes, so the words inside an element have to count.
  case anyWord
  /// Only the script a wrapped runtime was handed — the first non-flag argument after
  /// the runtime's own flags. That argument is what the process *is*; everything after
  /// it is an argument to it.
  case scriptSlotOnly
}

/// The highest-scoring candidate across `processes`.
private nonisolated func bestAgentCandidate(
  in processes: [ForegroundProcess],
  tokens: TokenEvidence = .anyWord
) -> AgentCandidate? {
  var best: AgentCandidate?
  for process in processes {
    for candidate in agentCandidates(for: process, tokens: tokens) {
      guard let agent = identifyAgent(candidate: candidate, process: process) else { continue }
      if best == nil || candidate.score > best!.score {
        best = AgentCandidate(score: candidate.score, agent: agent, name: candidate.name, process: process)
      }
    }
  }
  return best
}

/// The agent a launcher is hosting, from its descendants in breadth-first order.
///
/// Two rules, in this order.
///
/// **Which agent** is the one nearest the launcher: that is the session the launcher
/// started. An agent goes on to spawn its own work — subagents, tool processes, even a
/// documented `claude mcp serve` — and a different agent down there must never take
/// the pane's identity from it.
///
/// **Which process** of that agent is the one with the strongest evidence. A wrapped
/// runtime appears twice: `codex` is a node script that spawns a native binary, and it
/// is the native process that holds the session file open — and the published pid is
/// what session resolution and native state are read from, so the shim's pid would
/// find nothing. Evidence is exactly the right discriminator: the shim is named by its
/// script, the engine by its own `argv0`.
///
/// A hosted process may only be named by what it *is*: its `argv0`, its comm name, or
/// the script a wrapped runtime was handed. That last one is load-bearing — an agent
/// packaged as pure JavaScript (`gemini`, `qwen`, `cline`) runs entirely inside node,
/// so the kernel reports `argv0` and comm as `node` and only the script names it.
/// Everything after the script is an argument: Happy's own shim carries a
/// `--mcp-config` JSON blob and a prompt file there, and trusting those would let the
/// shim impersonate whatever an MCP server happens to be called.
private nonisolated func hostedAgentCandidate(in hosted: [ForegroundProcess]) -> AgentCandidate? {
  var best: AgentCandidate?
  for process in hosted {
    guard let candidate = bestAgentCandidate(in: [process], tokens: .scriptSlotOnly) else { continue }
    guard let current = best else {
      best = candidate
      continue
    }
    // A deeper process only replaces the pick as a better-evidenced view of the same
    // agent; a different agent deeper down is that agent's own work.
    if candidate.agent == current.agent, candidate.score > current.score {
      best = candidate
    }
  }
  return best
}

private nonisolated func agentCandidates(
  for process: ForegroundProcess,
  tokens: TokenEvidence = .anyWord
) -> [(name: String, score: Int)] {
  var candidates: [(String, Int)] = []
  let arguments = process.arguments ?? process.cmdline?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
  // agy spawns a transient `--bg-updater` child in the same foreground job
  // (verified argv on 1.3.1: `agy --bg-updater --app_data_dir=…`). It shares
  // argv0 but holds no presence lock, so the interactive TUI must always win
  // the pick. The pinned first position keeps a prompt payload that merely
  // mentions the token from demoting the real TUI.
  // agy's Go-style flags accept one dash too, so `-bg-updater` spells the
  // same updater mode.
  let isAntigravityUpdater =
    arguments.dropFirst().first == "--bg-updater"
    || arguments.dropFirst().first == "-bg-updater"

  if let argv0 = process.argv0, let name = normalizedProcessName(argv0) {
    // The REPL delegates to `devin acp`, which owns the native session lock.
    // Keep the shell-launched parent as launchProcess while resolving that child.
    let isDevinEngine = name == "devin" && arguments.dropFirst().first == "acp"
    let demoted = isAntigravityUpdater && identifyAgent(processName: name) == .antigravity
    candidates.append((name, isDevinEngine ? 90 : demoted ? 60 : 80))
  }
  if let name = normalizedProcessName(process.name) {
    // Demote the comm-name candidate too (50 clears the score-40 wrapped-runtime
    // guard), or a missing TUI argv0 would tie the pick at 70.
    let demoted = isAntigravityUpdater && identifyAgent(processName: name) == .antigravity
    candidates.append((name, demoted ? 50 : 70))
  }

  let primaryName = normalizedProcessName(process.argv0 ?? process.name) ?? process.name.lowercased()
  // A launcher's remaining arguments say what the user asked it to start, not what is
  // running here: `node …/happy codex` is still Happy, and the Codex it names runs in
  // another process entirely. Letting that token match would pin the pane to the
  // launcher's own pid and hide the engine the walk went to find.
  let namesAnotherProcessesWork = AgentLauncher.hostsAgentsOutsideJob(process)
  if isWrappedRuntime(primaryName), !namesAnotherProcessesWork {
    for token in runtimeTokens(arguments: arguments, tokens: tokens) {
      guard let name = normalizedProcessName(token) else { continue }
      candidates.append((name, weakCandidateScore))
    }
  }

  return candidates
}

/// The tokens of a wrapped runtime that may name an agent, under `tokens`.
private nonisolated func runtimeTokens(arguments: [String], tokens: TokenEvidence) -> [String] {
  switch tokens {
  case .anyWord:
    // Every word, which is every argv element split on whitespace — the in-job rule
    // unchanged.
    return arguments.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
  case .scriptSlotOnly:
    // The same position lock `AgentLauncher` uses: the first non-flag argument after
    // the runtime's own flags, and only that one.
    //
    // Two shapes it declines rather than guess at: a runtime flag that swallowed its
    // value, and a package-manager subcommand whose script slot is the subcommand
    // (`bun run gemini`, `npm exec gemini`). Both cost a detection instead of naming
    // the wrong process. Neither is how a launcher starts an agent — Happy spawns the
    // resolved path — so the trade is cheap here.
    return arguments.dropFirst().first { !$0.hasPrefix("-") }.map { [$0] } ?? []
  }
}

/// The score of a command-line token candidate: the weakest evidence there is, since
/// a token can be a payload, a model id, or a path the process merely mentions.
private nonisolated let weakCandidateScore = 40

private nonisolated func identifyAgent(
  candidate: (name: String, score: Int),
  process: ForegroundProcess
) -> DetectedAgent? {
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
  // Grok Build, Devin, Antigravity, and TraeCode CLI are native executables, not
  // wrapped-runtime scripts. Their names can also appear as model arguments or
  // quoted prompt tokens in a wrapper's cmdline; require argv0/name evidence.
  if [
    "grok", "devin", "agy", "antigravity-cli", "antigravity_cli",
    "traecli", "traex", "trae-cli", "trae-agent",
  ].contains(candidate.name), candidate.score == weakCandidateScore {
    return nil
  }
  return identifyAgent(processName: candidate.name)
}

private nonisolated func isCursorAgentAlias(_ process: ForegroundProcess) -> Bool {
  let haystack = agentAliasHaystack(process)
  return haystack.contains("cursor-agent")
    || haystack.contains("cursor.app")
}

private nonisolated func isGrokAgentAlias(_ process: ForegroundProcess) -> Bool {
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

private nonisolated func agentAliasHaystack(_ process: ForegroundProcess) -> String {
  [
    process.argv0,
    process.cmdline,
  ]
  .compactMap(\.self)
  .joined(separator: " ")
  .lowercased()
}

private nonisolated struct AgentCandidate {
  let score: Int
  let agent: DetectedAgent
  let name: String
  let process: ForegroundProcess
}

/// Executable suffixes that are packaging, not identity. Claude Code ships its
/// native binary as `claude.exe` on every platform (`bin/claude.exe`, verified on
/// 2.1.241), and that is the name a spawn by absolute path carries — a shell launch
/// says `claude` in argv0 and hid this until launcher-hosted engines were read.
private nonisolated let strippedExecutableSuffixes = [".js", ".exe"]

/// Pure name helpers, shared with the `nonisolated` process probe that decides whose
/// descendants to walk.
private nonisolated func normalizedProcessName(_ raw: String) -> String? {
  guard let basename = ProcessDetection.basename(raw) else { return nil }
  let lower = basename.lowercased()
  for suffix in strippedExecutableSuffixes where lower.hasSuffix(suffix) {
    return String(lower.dropLast(suffix.count))
  }
  return lower
}

private nonisolated func isWrappedRuntime(_ name: String) -> Bool {
  [
    "node", "bun", "python", "python3", "ruby", "deno",
    "sh", "bash", "zsh", "fish", "tmux", "npx", "bunx",
  ].contains(name)
}
