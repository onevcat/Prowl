import Foundation

private nonisolated let agentSessionLogger = SupaLogger("AgentSession")

nonisolated struct AgentSession: Equatable, Sendable {
  enum Source: String, Equatable, Sendable {
    case commandLine = "command_line"
    case openFile = "open_file"
    case processLog = "process_log"
    case storeRecord = "store_record"
    case transcriptMatch = "transcript_match"
    case recentFile = "recent_file"
  }

  enum Confidence: String, Equatable, Sendable {
    case exact
    case high
    case medium
  }

  let id: String
  let transcriptPath: URL?
  let source: Source
  let confidence: Confidence

  init(
    id: String,
    transcriptPath: URL?,
    source: Source,
    confidence: Confidence = .medium
  ) {
    self.id = id
    self.transcriptPath = transcriptPath
    self.source = source
    self.confidence = confidence
  }
}

nonisolated struct AgentSessionCandidate: Equatable, Sendable {
  let session: AgentSession
  let modifiedAt: Date

  /// The sole session active during the process lifetime, or nil when zero or
  /// several distinct sessions qualify. Grouping by session id keeps layouts
  /// with several files per session (Kimi, Cline, Copilot) resolvable.
  nonisolated static func uniqueActiveCandidate(
    _ candidates: [Self],
    processStartedAt: Date,
    clockSkew: TimeInterval = 2
  ) -> Self? {
    let active = candidates.filter { $0.modifiedAt >= processStartedAt.addingTimeInterval(-clockSkew) }
    let sessions = Dictionary(grouping: active) { $0.session.id }
    guard sessions.count == 1, let group = sessions.values.first else { return nil }
    return group.max { $0.modifiedAt < $1.modifiedAt }
  }
}

nonisolated extension [AgentSessionCandidate] {
  /// Store rows queried under two cwd variants can duplicate a session.
  fileprivate func uniquedBySessionID() -> [AgentSessionCandidate] {
    var seen: Set<String> = []
    return filter { seen.insert($0.session.id).inserted }
  }
}

/// Outcome of one resolver call: `isFresh` distinguishes a newly computed
/// resolution from a cache replay during backoff.
nonisolated struct AgentSessionResolution: Sendable {
  let session: AgentSession?
  let isFresh: Bool
}

/// Parsed, normalized transcript fragments reused across resolver polls and panes.
///
/// Fingerprint matching re-reads the same transcript tails every time a pane's
/// session cache expires (5 s while a session stays resolved). The bytes are
/// almost always identical and the tails sit in the page cache, so the cost is
/// re-parsing JSON and re-normalizing text rather than I/O. Keying the parsed
/// result on the file's modification time replays it for unchanged transcripts
/// without altering which candidate wins. Entry-count and retained-payload limits
/// bound process churn and candidate-set churn independently of process cleanup.
nonisolated struct TranscriptFragmentCache: Sendable {
  struct Key: Hashable, Sendable {
    let path: String
    let modifiedAt: Date
  }

  /// One normalized transcript fragment, with the two derived values scoring
  /// needs. Both are precomputed because `String.count` walks graphemes and
  /// `suffix` allocates — costs that would otherwise be paid per fragment on
  /// every match, for text that never changes.
  struct Fragment: Sendable, Equatable {
    let text: String
    let characterCount: Int
    /// The trailing 80 characters, present only when the fragment is longer
    /// than that. A shorter fragment's suffix is the fragment itself, so
    /// testing it would repeat the full-text test verbatim.
    let suffix: String?

    init(text: String) {
      self.text = text
      let count = text.count
      characterCount = count
      suffix = count > 80 ? String(text.suffix(80)) : nil
    }

    /// What this fragment costs the retention budget. `suffix` is a separate
    /// allocation rather than a view into `text`, so it is counted too.
    var retainedUTF8Bytes: Int {
      text.utf8.count + (suffix?.utf8.count ?? 0)
    }
  }

  private struct Entry: Sendable {
    let fragments: [Fragment]
    let retainedUTF8Bytes: Int
    var lastAccess: UInt64
  }

  private var entries: [Key: Entry] = [:]
  private var retainedUTF8Bytes = 0
  private var accessCounter: UInt64 = 0
  private let maxEntryCount: Int
  private let maxRetainedUTF8Bytes: Int

  init(
    maxEntryCount: Int = 128,
    maxRetainedUTF8Bytes: Int = 8 * 1_024 * 1_024
  ) {
    self.maxEntryCount = max(0, maxEntryCount)
    self.maxRetainedUTF8Bytes = max(0, maxRetainedUTF8Bytes)
  }

  var count: Int { entries.count }

  /// Returns the cached fragments for `key`, otherwise stores and returns
  /// `load()`. A nil `load()` is deliberately not cached: an unreadable tail is
  /// transient, and caching the failure would keep a recovered file excluded.
  mutating func fragments(for key: Key, load: () -> [Fragment]?) -> [Fragment]? {
    accessCounter &+= 1
    if var cached = entries[key] {
      cached.lastAccess = accessCounter
      entries[key] = cached
      return cached.fragments
    }
    // Only the newest observed version of a path can be useful. Removing older
    // modification-time keys immediately avoids spending the shared budget on
    // append history until LRU pressure happens to arrive. Do this even when
    // the new version is temporarily unreadable: an old key cannot answer a
    // request for the new file contents.
    for superseded in entries.keys.filter({ $0.path == key.path }) {
      remove(superseded)
    }
    guard let loaded = load() else { return nil }

    let byteCount =
      key.path.utf8.count
      + loaded.reduce(into: 0) { count, fragment in
        count += fragment.retainedUTF8Bytes
      }
    guard maxEntryCount > 0, byteCount <= maxRetainedUTF8Bytes else { return loaded }
    entries[key] = Entry(
      fragments: loaded,
      retainedUTF8Bytes: byteCount,
      lastAccess: accessCounter
    )
    retainedUTF8Bytes += byteCount
    evictIfNeeded()
    return loaded
  }

  private mutating func evictIfNeeded() {
    while entries.count > maxEntryCount || retainedUTF8Bytes > maxRetainedUTF8Bytes {
      guard let leastRecentlyUsed = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
      else { return }
      remove(leastRecentlyUsed)
    }
  }

  private mutating func remove(_ key: Key) {
    guard let removed = entries.removeValue(forKey: key) else { return }
    retainedUTF8Bytes -= removed.retainedUTF8Bytes
  }
}

/// Compatibility shim over the per-agent profiles; the actual rules live in
/// `AgentSessionProfile`.
nonisolated enum AgentSessionPathParser {
  static func parse(path: String, agent: DetectedAgent) -> AgentSession? {
    AgentSessionProfile.profile(for: agent).parsePath(path)
  }
}

actor AgentSessionResolver {
  static let shared = AgentSessionResolver()

  private struct CacheKey: Hashable {
    let pid: pid_t
    let startedAt: Date
  }

  private struct CachedResult {
    let resolvedAt: Date
    let session: AgentSession?
    let usedWideScan: Bool
    var unresolvedStreak: Int = 0
    var provisionalSoleID: String?
  }

  /// The immutable inputs of one uncached resolution, grouped so the scan and
  /// match steps take a single subject rather than a long parameter list.
  private struct ResolveRequest {
    let identified: IdentifiedAgentProcess
    let processStartedAt: Date
    let workingDirectory: URL?
    let activeText: String
    /// A relocated agent config root, when the runtime supports one. Selects the
    /// rooted path parser and candidate roots, and suppresses the pid-keyed
    /// lookup, whose artifacts only ever live in the default home.
    let configRoot: URL?
    let now: Date
  }

  private struct ResolveInput {
    let identified: IdentifiedAgentProcess
    let workingDirectory: URL?
    let activeText: String
    let configRoot: URL?
    let now: Date
  }

  /// Unresolved lookups retry quickly while the narrow scan stays cheap, then
  /// back off exponentially while the pane stays ambiguous; wide fallback
  /// scans (full history trees) start at the slow end. 15 s cap keeps a
  /// permanently ambiguous pane at negligible background cost while still
  /// converging after a session rotation.
  nonisolated static func cacheLifetime(hasSession: Bool, usedWideScan: Bool, unresolvedStreak: Int) -> TimeInterval {
    if hasSession { return 5 }
    let base: TimeInterval = usedWideScan ? 8 : 1
    return min(15, base * TimeInterval(1 << min(unresolvedStreak, 4)))
  }

  /// resolved → ambiguous starts a new unresolved episode at streak 0 (the
  /// first retry keeps the fast pacing, e.g. right after `/clear`); only
  /// consecutive unresolved results escalate the backoff.
  nonisolated static func nextUnresolvedStreak(
    resolvedNow: Bool,
    previousWasUnresolved: Bool,
    previousStreak: Int
  ) -> Int {
    guard !resolvedNow, previousWasUnresolved else { return 0 }
    return previousStreak + 1
  }

  /// A sole process-lifetime candidate is only trusted after two consecutive
  /// resolutions agree on it. A pane that starts in a directory where another
  /// agent is actively writing can otherwise adopt that agent's session during
  /// the sub-second window before its own file lands.
  nonisolated static func confirmSole(
    _ session: AgentSession?,
    previousProvisionalID: String?
  ) -> (session: AgentSession?, provisionalID: String?) {
    guard let session else { return (nil, nil) }
    guard session.confidence == .medium else { return (session, nil) }
    guard session.id == previousProvisionalID else { return (nil, session.id) }
    return (session, nil)
  }

  /// One directory walk, reusable by every pane that scans the same root.
  ///
  /// Panes resolve independently but overwhelmingly share roots: every agent in
  /// one project enumerates that project's transcript directory. The walk is the
  /// dominant filesystem cost and grows with the number of files on disk rather
  /// than the number of panes, so repeating it per pane is pure duplication.
  /// Files are stored unfiltered because callers apply their own
  /// process-start threshold.
  private struct RootScan {
    let scannedAt: Date
    /// `nil` when the walk exceeded its visit limit — see `recentFiles`.
    let files: [(url: URL, modifiedAt: Date)]?
  }

  /// The visit limit is part of the key: a walk made under a looser limit may
  /// have kept entries a stricter caller would have refused to trust, so it
  /// cannot answer on that caller's behalf.
  private struct RootScanKey: Hashable {
    let root: URL
    let visitLimit: Int
  }

  /// How long one root's walk may be replayed. This must not outlive the narrow
  /// one-second retry used to confirm a medium-confidence sole candidate: that
  /// confirmation needs a fresh enumeration so a newly created competing
  /// transcript can prevent a false attribution. One second still collapses the
  /// burst of panes that resolve at nearly the same time.
  private static let rootScanLifetime: TimeInterval = 1

  private var cache: [CacheKey: CachedResult] = [:]
  /// Transcript parsing depends only on file identity, not on the process doing
  /// the match. Sharing one bounded cache avoids retaining duplicate 128 KiB
  /// tails for every pane that consults the same candidate set.
  private var fragmentCache = TranscriptFragmentCache()
  private var rootScans: [RootScanKey: RootScan] = [:]
  private let fileManager: FileManager
  private let homeDirectory: URL

  init(
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.fileManager = fileManager
    self.homeDirectory = homeDirectory
  }

  func resolve(
    identified: IdentifiedAgentProcess,
    workingDirectory: URL?,
    activeText: String,
    configRoot: URL? = nil,
    now: Date = Date()
  ) -> AgentSessionResolution {
    resolve(
      ResolveInput(
        identified: identified,
        workingDirectory: workingDirectory,
        activeText: activeText,
        configRoot: configRoot,
        now: now
      ),
      bypassResultCache: false
    )
  }

  /// Recomputes session attribution from current process/screen evidence instead
  /// of replaying a `PaneAgentState` or pid-result cache entry. File/root parsing
  /// caches remain valid optimizations because they are keyed by file identity.
  func resolveFresh(
    identified: IdentifiedAgentProcess,
    workingDirectory: URL?,
    activeText: String,
    configRoot: URL? = nil,
    now: Date = Date()
  ) -> AgentSessionResolution {
    resolve(
      ResolveInput(
        identified: identified,
        workingDirectory: workingDirectory,
        activeText: activeText,
        configRoot: configRoot,
        now: now
      ),
      bypassResultCache: true
    )
  }

  private func resolve(_ input: ResolveInput, bypassResultCache: Bool) -> AgentSessionResolution {
    let identified = input.identified
    let workingDirectory = input.workingDirectory
    let activeText = input.activeText
    let configRoot = input.configRoot
    let now = input.now
    let process = identified.process
    guard let startedAt = ProcessDetection.processStartDate(pid: process.pid) else {
      return AgentSessionResolution(session: nil, isFresh: true)
    }
    let key = CacheKey(pid: process.pid, startedAt: startedAt)
    let cached = cache[key]
    if !bypassResultCache, let cached {
      let lifetime = Self.cacheLifetime(
        hasSession: cached.session != nil,
        usedWideScan: cached.usedWideScan,
        unresolvedStreak: cached.unresolvedStreak
      )
      if now.timeIntervalSince(cached.resolvedAt) < lifetime {
        // Replayed cache hits are not new evidence; consumers must not age
        // their sticky sessions on them.
        return AgentSessionResolution(session: cached.session, isFresh: false)
      }
    }

    let (resolved, usedWideScan) = resolveUncached(
      ResolveRequest(
        identified: identified,
        processStartedAt: startedAt,
        workingDirectory: workingDirectory,
        activeText: activeText,
        configRoot: configRoot,
        now: now
      ),
      fragments: &fragmentCache
    )
    var session = resolved
    var provisionalID: String?
    if let candidate = session, candidate.confidence == .medium {
      if claimedByAnotherProcess(candidate.id, excluding: key) {
        session = nil
      } else {
        (session, provisionalID) = Self.confirmSole(candidate, previousProvisionalID: cached?.provisionalSoleID)
      }
    }
    cache[key] = CachedResult(
      resolvedAt: now,
      session: session,
      usedWideScan: usedWideScan,
      // A pending sole confirmation retries fast instead of backing off.
      unresolvedStreak: Self.nextUnresolvedStreak(
        resolvedNow: session != nil || provisionalID != nil,
        previousWasUnresolved: cached.map { $0.session == nil && $0.provisionalSoleID == nil } ?? false,
        previousStreak: cached?.unresolvedStreak ?? 0
      ),
      provisionalSoleID: provisionalID
    )
    if cache.count > 128 {
      cache = cache.filter { entry in
        ProcessDetection.processStartDate(pid: entry.key.pid) == entry.key.startedAt
      }
    }
    return AgentSessionResolution(session: session, isFresh: true)
  }

  /// A session id already resolved for a different live process cannot also
  /// belong to this one; sole-candidate attribution must not steal it.
  private func claimedByAnotherProcess(_ id: String, excluding key: CacheKey) -> Bool {
    cache.contains { entry in
      entry.key != key && entry.value.session?.id == id
        && ProcessDetection.processStartDate(pid: entry.key.pid) == entry.key.startedAt
    }
  }

  /// Selects the path parser for this surface: the rooted variant when a
  /// relocated config root is in play (docs-ai 053), the default markers
  /// otherwise.
  nonisolated static func pathParser(
    profile: AgentSessionProfile,
    configRoot: URL?
  ) -> @Sendable (String) -> AgentSession? {
    if let configRoot, let rooted = profile.rootedParsePath {
      return { rooted($0, configRoot) }
    }
    return profile.parsePath
  }

  private func resolveUncached(
    _ request: ResolveRequest,
    fragments cache: inout TranscriptFragmentCache
  ) -> (session: AgentSession?, usedWideScan: Bool) {
    let identified = request.identified
    let profile = AgentSessionProfile.profile(for: identified.agent)
    let parsePath = Self.pathParser(profile: profile, configRoot: request.configRoot)

    let openSessions = ProcessDetection.openFilePaths(pid: identified.process.pid)
      .compactMap { parsePath($0) }
      .compactMap { session -> AgentSession? in
        guard let path = session.transcriptPath,
          let fullID = Self.sessionIDFromHeader(at: path, keys: profile.headerSessionIDKeys)
        else {
          return profile.requiresHeaderSessionID ? nil : session
        }
        return AgentSession(id: fullID, transcriptPath: path, source: session.source)
      }
    if let session = uniqueSession(openSessions) {
      let resolved = AgentSession(
        id: session.id,
        transcriptPath: session.transcriptPath,
        source: .openFile,
        confidence: .exact
      )
      return (resolved, false)
    }

    if let configRoot = request.configRoot,
      let session = profile.rootedPIDKeyedSession?(
        configRoot,
        identified.process.pid,
        request.processStartedAt
      )
    {
      return (session, false)
    }
    if request.configRoot == nil,
      let session = profile.pidKeyedSession?(homeDirectory, identified.process.pid, request.processStartedAt)
    {
      return (session, false)
    }

    let openCandidates = openSessions.compactMap { session -> AgentSessionCandidate? in
      guard let path = session.transcriptPath,
        let attributes = try? fileManager.attributesOfItem(atPath: path.path),
        let modifiedAt = attributes[.modificationDate] as? Date
      else { return nil }
      return AgentSessionCandidate(session: session, modifiedAt: modifiedAt)
    }
    if let matched = AgentSessionFingerprintMatcher.bestMatch(
      activeText: request.activeText,
      candidates: openCandidates,
      fragments: &cache
    ) {
      let resolved = AgentSession(
        id: matched.session.id,
        transcriptPath: matched.session.transcriptPath,
        source: .transcriptMatch,
        confidence: .high
      )
      return (resolved, false)
    }

    let (candidates, usedWideScan) = recentCandidates(
      profile: profile,
      processStartedAt: request.processStartedAt,
      workingDirectory: request.workingDirectory,
      configRoot: request.configRoot,
      now: request.now
    )
    if let matched = AgentSessionFingerprintMatcher.bestMatch(
      activeText: request.activeText,
      candidates: candidates,
      fragments: &cache
    ) {
      let resolved = AgentSession(
        id: matched.session.id,
        transcriptPath: matched.session.transcriptPath,
        source: .transcriptMatch,
        confidence: .high
      )
      return (resolved, usedWideScan)
    }
    let sole = AgentSessionCandidate.uniqueActiveCandidate(candidates, processStartedAt: request.processStartedAt)?
      .session
    return (sole, usedWideScan)
  }

  private func uniqueSession(_ sessions: [AgentSession]) -> AgentSession? {
    let unique = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return unique.count == 1 ? unique.values.first : nil
  }

  func recentCandidates(
    profile: AgentSessionProfile,
    processStartedAt: Date,
    workingDirectory: URL?,
    configRoot: URL? = nil,
    now: Date,
    visitLimit: Int = 20_000
  ) -> (candidates: [AgentSessionCandidate], usedWideScan: Bool) {
    let cwdVariants = workingDirectoryVariants(workingDirectory)
    let threshold = processStartedAt.addingTimeInterval(-2)
    // Under a relocated config root the rooted layout is used exclusively:
    // scanning the default home would misattribute another account's
    // sessions. Store-backed agents cannot be account-bound.
    let stored =
      configRoot == nil
      ? cwdVariants.flatMap { profile.storeCandidates?(homeDirectory, $0, threshold) ?? [] }
      : []
    var primaryRoots: [URL] = []
    for cwd in cwdVariants {
      let roots =
        if let configRoot {
          profile.rootedCandidateRoots?(configRoot, cwd, processStartedAt, now) ?? []
        } else {
          profile.candidateRoots(homeDirectory, cwd, processStartedAt, now)
        }
      for root in roots where !primaryRoots.contains(root) {
        primaryRoots.append(root)
      }
    }
    guard
      let primary = scanCandidates(
        in: primaryRoots,
        profile: profile,
        processStartedAt: processStartedAt,
        configRoot: configRoot,
        visitLimit: visitLimit,
        now: now
      )
    else {
      // A truncated primary scan voids this whole round: the fallback tree is
      // a superset and would only repeat the oversized enumeration. Report it
      // as a wide scan so the retry backs off at the slow tier.
      return ([], true)
    }
    let combined = primary + stored.uniquedBySessionID()
    guard combined.isEmpty else { return (combined, false) }
    let fallbackRoots =
      if let configRoot {
        profile.rootedFallbackRoots?(configRoot, workingDirectory) ?? []
      } else {
        profile.fallbackRoots(homeDirectory, workingDirectory)
      }
    guard !fallbackRoots.isEmpty else { return ([], false) }
    let fallback = scanCandidates(
      in: fallbackRoots,
      profile: profile,
      processStartedAt: processStartedAt,
      configRoot: configRoot,
      visitLimit: visitLimit,
      now: now
    )
    return (fallback ?? [], true)
  }

  /// The pane reports the shell's logical `$PWD` while agents usually record
  /// the physical path (`/tmp` vs `/private/tmp`); try both encodings.
  private func workingDirectoryVariants(_ cwd: URL?) -> [URL?] {
    guard let cwd else { return [nil] }
    let resolved = cwd.resolvingSymlinksInPath()
    return resolved.path == cwd.path ? [cwd] : [cwd, resolved]
  }

  /// Scans `roots` for session files modified during the process lifetime.
  /// Returns nil when any enumeration was truncated: an incomplete view could
  /// declare a false unique candidate, and unresolved is the safe outcome.
  func scanCandidates(
    in roots: [URL],
    profile: AgentSessionProfile,
    processStartedAt: Date,
    configRoot: URL? = nil,
    visitLimit: Int = 20_000,
    now: Date = Date()
  ) -> [AgentSessionCandidate]? {
    var collected: [AgentSessionCandidate] = []
    for root in roots {
      guard
        let files = recentFiles(
          in: root,
          modifiedAfter: processStartedAt.addingTimeInterval(-2),
          visitLimit: visitLimit,
          now: now
        )
      else { return nil }
      for item in files {
        guard let candidate = enrichedCandidate(for: item, profile: profile, configRoot: configRoot)
        else { continue }
        collected.append(candidate)
      }
    }
    return collected
  }

  private func enrichedCandidate(
    for item: (url: URL, modifiedAt: Date),
    profile: AgentSessionProfile,
    configRoot: URL?
  ) -> AgentSessionCandidate? {
    guard let session = Self.pathParser(profile: profile, configRoot: configRoot)(item.url.path) else { return nil }
    if let fullID = Self.sessionIDFromHeader(at: item.url, keys: profile.headerSessionIDKeys) {
      return AgentSessionCandidate(
        session: AgentSession(id: fullID, transcriptPath: item.url, source: .recentFile),
        modifiedAt: item.modifiedAt
      )
    }
    // A profile that depends on the header (Gemini's filenames only carry a
    // truncated id) must not surface the unusable path-derived id.
    guard !profile.requiresHeaderSessionID else { return nil }
    return AgentSessionCandidate(session: session, modifiedAt: item.modifiedAt)
  }

  nonisolated static func sessionIDFromHeader(at url: URL, keys: [String]) -> String? {
    guard !keys.isEmpty, url.pathExtension == "jsonl",
      let handle = try? FileHandle(forReadingFrom: url)
    else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 8_192),
      let line = data.split(separator: 0x0A).first,
      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    else { return nil }
    for key in keys {
      if let value = object[key] as? String, !value.isEmpty { return value }
    }
    return nil
  }

  /// Returns nil when the enumeration exceeded `visitLimit`: a partial view
  /// must void the whole scan rather than feed uniqueness checks.
  ///
  /// The walk itself is shared through `rootScans`; only the threshold filter is
  /// per caller, so two panes with different process start times still reuse one
  /// enumeration.
  private func recentFiles(
    in root: URL,
    modifiedAfter threshold: Date,
    visitLimit: Int,
    now: Date
  ) -> [(url: URL, modifiedAt: Date)]? {
    guard let files = scannedFiles(in: root, visitLimit: visitLimit, now: now) else { return nil }
    return files.filter { $0.modifiedAt >= threshold }
  }

  /// Every regular file under `root` with its modification date, replayed from
  /// `rootScans` while the previous walk is still fresh.
  private func scannedFiles(
    in root: URL,
    visitLimit: Int,
    now: Date
  ) -> [(url: URL, modifiedAt: Date)]? {
    let key = RootScanKey(root: root, visitLimit: visitLimit)
    if let cached = rootScans[key], now.timeIntervalSince(cached.scannedAt) < Self.rootScanLifetime {
      return cached.files
    }
    let files = enumerateFiles(in: root, visitLimit: visitLimit)
    rootScans[key] = RootScan(scannedAt: now, files: files)
    if rootScans.count > 64 {
      rootScans = rootScans.filter { now.timeIntervalSince($0.value.scannedAt) < Self.rootScanLifetime }
    }
    return files
  }

  private func enumerateFiles(in root: URL, visitLimit: Int) -> [(url: URL, modifiedAt: Date)]? {
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    var visited = 0
    var result: [(URL, Date)] = []
    for case let url as URL in enumerator {
      visited += 1
      if visited > visitLimit {
        agentSessionLogger.warning("Agent session scan truncated at \(visitLimit) entries under \(root.path)")
        return nil
      }
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
        values.isRegularFile == true,
        let modifiedAt = values.contentModificationDate
      else { continue }
      result.append((url, modifiedAt))
    }
    return result
  }
}

nonisolated enum AgentSessionFingerprintMatcher {
  /// Convenience for call sites with no cache to reuse (tests, one-shot lookups).
  static func bestMatch(
    activeText: String,
    candidates: [AgentSessionCandidate]
  ) -> AgentSessionCandidate? {
    var scratch = TranscriptFragmentCache()
    return bestMatch(activeText: activeText, candidates: candidates, fragments: &scratch)
  }

  static func bestMatch(
    activeText: String,
    candidates: [AgentSessionCandidate],
    fragments cache: inout TranscriptFragmentCache
  ) -> AgentSessionCandidate? {
    let screen = normalize(activeText)
    guard screen.count >= 12 else { return nil }
    // Bound tail reads WITHOUT evicting whole sessions: cap files per session
    // (extra files of one session only reinforce it), and refuse to declare
    // uniqueness when there are more sessions than the read budget covers —
    // an unexamined session could hold the same text.
    let bySession = Dictionary(grouping: candidates) { $0.session.id }
    guard bySession.count <= 12 else { return nil }
    var scored: [(AgentSessionCandidate, Int)] = []
    for group in bySession.values {
      var sessionScoreable = false
      for candidate in group.sorted(by: { $0.modifiedAt > $1.modifiedAt }).prefix(2) {
        // Scoreable means the session produced at least one fragment long
        // enough to actually enter the comparison — fragments below the floor
        // ("OK") are no testimony at all.
        guard let path = candidate.session.transcriptPath,
          let comparable = comparableFragments(at: path, modifiedAt: candidate.modifiedAt, cache: &cache)
        else { continue }
        if !comparable.isEmpty { sessionScoreable = true }
        let score = comparable.reduce(0) { best, fragment in
          if screen.contains(fragment.text) { return max(best, min(200, fragment.characterCount + 80)) }
          // Only a fragment longer than the window has a suffix distinct from
          // itself; for the rest the full-text test above already answered.
          guard let suffix = fragment.suffix else { return best }
          return screen.contains(suffix) ? max(best, 80) : best
        }
        if score > 0 { scored.append((candidate, score)) }
      }
      // A session that yields no comparable text at all (unreadable tail,
      // oversized single-line JSON, no supported fields) might still be the
      // real one; uniqueness cannot be declared over its silence. A scoreable
      // session that merely scores zero HAS testified — it stays eliminable.
      guard sessionScoreable else { return nil }
    }

    // The margin rule guards against picking between *sessions* that look
    // alike; files belonging to one session reinforce it instead of competing.
    let sessions = Dictionary(grouping: scored) { $0.0.session.id }
      .map { id, group in
        (id: id, best: group.max { $0.1 < $1.1 }!)
      }
      .sorted { $0.best.1 > $1.best.1 }

    guard let winner = sessions.first, winner.best.1 >= 40 else { return nil }
    if sessions.count > 1, winner.best.1 - sessions[1].best.1 < 20 { return nil }
    return winner.best.0
  }

  /// Normalized, length-filtered fragments for one transcript tail, served from
  /// `cache` whenever the file has not been appended to since the last poll.
  private static func comparableFragments(
    at path: URL,
    modifiedAt: Date,
    cache: inout TranscriptFragmentCache
  ) -> [TranscriptFragmentCache.Fragment]? {
    cache.fragments(for: TranscriptFragmentCache.Key(path: path.path, modifiedAt: modifiedAt)) {
      guard let data = tailData(at: path) else { return nil }
      // Lossy decoding is deliberate: the tail window can start mid-character
      // in a multi-byte transcript, and a failable conversion would void the
      // whole tail instead of just the cut first line.
      // swiftlint:disable:next optional_data_string_conversion
      return transcriptStrings(String(decoding: data, as: UTF8.self))
        .map { TranscriptFragmentCache.Fragment(text: normalize($0)) }
        .filter { $0.characterCount >= 12 }
    }
  }

  /// Strips ANSI escapes, folds case, and collapses whitespace runs so screen
  /// text and transcript text compare on content alone.
  ///
  /// The ASCII fast path exists because this runs over every transcript fragment
  /// of every fingerprint match and dominated the resolver's CPU: Swift Regex
  /// and grapheme-level whitespace splitting are both far more expensive than a
  /// single byte scan. Any non-ASCII byte defers to `normalizeGeneral`, so
  /// Unicode case folding and the full Unicode whitespace set keep their exact
  /// semantics rather than being approximated.
  static func normalize(_ value: String) -> String {
    normalizeASCII(value) ?? normalizeGeneral(value)
  }

  /// Reference implementation. `normalize` must agree with it for every input;
  /// `AgentSessionFingerprintNormalizeTests` asserts that over a corpus.
  static func normalizeGeneral(_ value: String) -> String {
    // A pattern anchored on ESC cannot match a string with no ESC byte, and
    // nearly every transcript fragment has none. Proving absence with a byte
    // scan is several times cheaper than letting the regex engine walk the
    // whole string to reach the same conclusion.
    let stripped =
      value.utf8.contains(0x1B)
      ? value.replacing(#/\u{001B}\[[0-?]*[ -\/]*[@-~]/#, with: " ")
      : value
    return
      stripped
      .lowercased()
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
  }

  /// Returns nil when `value` holds any non-ASCII byte, leaving those inputs to
  /// the general path.
  private static func normalizeASCII(_ value: String) -> String? {
    let utf8 = value.utf8
    // Built as scalars rather than bytes: every byte kept here is ASCII, so the
    // conversion is exact and needs no decoding pass over the result.
    var output = String.UnicodeScalarView()
    output.reserveCapacity(utf8.count)
    var pendingSeparator = false
    var index = utf8.startIndex

    while index < utf8.endIndex {
      let byte = utf8[index]
      guard byte < 0x80 else { return nil }
      // A well-formed CSI sequence becomes a space, which is itself a separator;
      // a bare ESC matches no sequence and survives as ordinary text.
      if byte == 0x1B, let end = csiEnd(utf8, from: index) {
        pendingSeparator = true
        index = end
        continue
      }
      if isASCIIWhitespace(byte) {
        pendingSeparator = true
      } else {
        // Leading whitespace produces no separator because nothing precedes it,
        // and a trailing run is simply never flushed — matching the trim that
        // `split` + `joined` performs.
        if pendingSeparator {
          if !output.isEmpty { output.append(Unicode.Scalar(UInt8(0x20))) }
          pendingSeparator = false
        }
        output.append(Unicode.Scalar(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte))
      }
      index = utf8.index(after: index)
    }
    return String(output)
  }

  /// The Unicode `White_Space` members that fall in the ASCII range.
  private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || (0x09...0x0D).contains(byte)
  }

  /// Index just past a CSI sequence starting at `start`, or nil if the bytes
  /// there do not form one: `ESC [` , parameters, intermediates, then a final byte.
  private static func csiEnd(
    _ utf8: String.UTF8View,
    from start: String.UTF8View.Index
  ) -> String.UTF8View.Index? {
    var index = utf8.index(after: start)
    guard index < utf8.endIndex, utf8[index] == 0x5B else { return nil }
    index = utf8.index(after: index)
    while index < utf8.endIndex, (0x30...0x3F).contains(utf8[index]) { index = utf8.index(after: index) }
    while index < utf8.endIndex, (0x20...0x2F).contains(utf8[index]) { index = utf8.index(after: index) }
    guard index < utf8.endIndex, (0x40...0x7E).contains(utf8[index]) else { return nil }
    return utf8.index(after: index)
  }

  private static func tailData(at url: URL, byteLimit: UInt64 = 131_072) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    try? handle.seek(toOffset: size > byteLimit ? size - byteLimit : 0)
    return try? handle.readToEnd()
  }

  private static func transcriptStrings(_ text: String) -> [String] {
    text.split(separator: "\n").suffix(80).flatMap { line -> [String] in
      guard let data = line.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data)
      else { return [] }
      return strings(in: json, key: nil)
    }
  }

  private static func strings(in value: Any, key: String?) -> [String] {
    if let string = value as? String,
      ["content", "text", "message", "result", "prompt", "last_assistant_message"].contains(key ?? "")
    {
      return [string]
    }
    if let array = value as? [Any] {
      return array.flatMap { strings(in: $0, key: key) }
    }
    if let object = value as? [String: Any] {
      return object.flatMap { strings(in: $0.value, key: $0.key) }
    }
    return []
  }
}
