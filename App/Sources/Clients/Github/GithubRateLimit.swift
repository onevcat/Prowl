import Foundation

// What one gh invocation said about the account's rate limit. A refusal means GitHub turned the
// request away; an exhausted budget means the request succeeded but spent the last of it, so the
// next one would be refused.
nonisolated struct GithubRateLimitSignal: Equatable, Sendable {
  var isRefusal: Bool
  var retryAfter: Duration?
  var resetAt: Date?
}

// Reads a rate-limit answer out of gh's output. `gh api --include` prints the response's status line
// and headers ahead of the body; other gh commands report only through stderr.
nonisolated enum GithubRateLimitClassifier {
  static func classify(stdout: String, stderr: String, succeeded: Bool) -> GithubRateLimitSignal? {
    let response = parseResponseHead(stdout)
    let retryAfter = response.fields["retry-after"].flatMap(Int.init).map { Duration.seconds($0) }
    let budgetExhausted = response.fields["x-ratelimit-remaining"] == "0"
    let resetAt =
      budgetExhausted
      ? response.fields["x-ratelimit-reset"].flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
      : nil
    let failed = !succeeded || (response.status ?? 200) >= 400
    let bodySaysLimited = bodyReportsRateLimit(stdout, includeTopLevelMessage: failed)
    let stderrSaysLimited = !succeeded && mentionsRateLimit(stderr)

    let isRefusal: Bool
    switch response.status {
    case 429:
      isRefusal = true
    case 403:
      // A 403 is also a permission answer; GitHub marks the rate-limit kind with these.
      isRefusal = retryAfter != nil || budgetExhausted || bodySaysLimited || stderrSaysLimited
    default:
      isRefusal = bodySaysLimited || stderrSaysLimited
    }
    if isRefusal {
      return GithubRateLimitSignal(isRefusal: true, retryAfter: retryAfter, resetAt: resetAt)
    }
    if budgetExhausted {
      return GithubRateLimitSignal(isRefusal: false, retryAfter: retryAfter, resetAt: resetAt)
    }
    return nil
  }

  private struct ResponseHead {
    var status: Int?
    var fields: [String: String] = [:]
  }

  // The status line may follow login-shell noise, so it is searched for rather than assumed first.
  private static func parseResponseHead(_ stdout: String) -> ResponseHead {
    var head = ResponseHead()
    var inHeaders = false
    for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if !inHeaders {
        guard trimmed.hasPrefix("HTTP/") else { continue }
        let parts = trimmed.split(separator: " ")
        head.status = parts.count > 1 ? Int(parts[1]) : nil
        inHeaders = true
        continue
      }
      guard !trimmed.isEmpty, let colon = trimmed.firstIndex(of: ":") else { break }
      let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      head.fields[name] = value
    }
    return head
  }

  // Only the top-level `errors` array, and on a failed response the top-level `message`, carry
  // GitHub's verdict. Payload text such as a pull request titled "Handle rate limits" never counts.
  private static func bodyReportsRateLimit(_ stdout: String, includeTopLevelMessage: Bool) -> Bool {
    for span in GithubCLIOutput.balancedJSONSpans(in: stdout) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(span.utf8)) as? [String: Any] else {
        continue
      }
      if let errors = object["errors"] as? [[String: Any]], errors.contains(where: isRateLimitError) {
        return true
      }
      if includeTopLevelMessage, let message = object["message"] as? String, mentionsRateLimit(message) {
        return true
      }
    }
    return false
  }

  private static func isRateLimitError(_ error: [String: Any]) -> Bool {
    let type = (error["type"] as? String)?.uppercased() ?? ""
    let code = (error["code"] as? String)?.lowercased() ?? ""
    let message = error["message"] as? String ?? ""
    return type == "RATE_LIMITED" || type == "RATE_LIMIT" || code.contains("rate_limit") || mentionsRateLimit(message)
  }

  private static func mentionsRateLimit(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return lowered.contains("rate limit") || lowered.contains("rate-limit") || lowered.contains("abuse detection")
  }
}

// One gate for every gh call that reaches GitHub. Several tools and agents share the account, and a
// refused request can extend a secondary limit for all of them, so once GitHub refuses, Prowl sends
// nothing until the retry time. Then exactly one request goes out as a probe; the others wait for its
// answer instead of racing it.
actor GithubRateLimitGate {
  static let shared = GithubRateLimitGate()

  static let initialBackoff: Duration = .seconds(60)
  static let maximumBackoff: Duration = .seconds(3600)

  struct Ticket: Sendable, Equatable {
    let isProbe: Bool
  }

  private enum Phase: Equatable {
    case open
    case blocked(until: Date)
    case probing(lastUntil: Date)
  }

  private let now: @Sendable () -> Date
  private let jitter: @Sendable () -> Double
  private var phase: Phase = .open
  private var consecutiveRefusals = 0
  private var waiters: [CheckedContinuation<Result<Ticket, GithubCLIError>, Never>] = []

  init(
    now: @escaping @Sendable () -> Date = { Date() },
    jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    self.now = now
    self.jitter = jitter
  }

  // Exponential from one minute, doubling per consecutive refusal, with up to 25% added jitter so
  // several clients do not return in step. Never above one hour.
  nonisolated static func backoff(afterRefusals refusals: Int, jitter: Double) -> Duration {
    let exponent = Double(min(max(refusals - 1, 0), 16))
    let initial = initialBackoff.timeInterval
    let delay = initial * pow(2.0, exponent) * (1.0 + 0.25 * min(max(jitter, 0), 1))
    return .seconds(min(delay, maximumBackoff.timeInterval))
  }

  var waitingRequestCount: Int {
    waiters.count
  }

  func admit() async throws -> Ticket {
    switch phase {
    case .open:
      return Ticket(isProbe: false)
    case .blocked(let until):
      if now() < until {
        throw GithubCLIError.rateLimited(retryAt: until)
      }
      phase = .probing(lastUntil: until)
      return Ticket(isProbe: true)
    case .probing:
      let result = await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
      return try result.get()
    }
  }

  // Records what GitHub answered a ticket. Returns the retry time when the request must be reported
  // as rate-limited, nil when its output stands.
  func record(_ ticket: Ticket, signal: GithubRateLimitSignal?) -> Date? {
    guard let signal else {
      if ticket.isProbe, case .probing = phase {
        reopen()
      }
      return nil
    }
    switch phase {
    case .open:
      let until = block(for: signal)
      return signal.isRefusal ? until : nil
    case .probing where ticket.isProbe:
      let until = block(for: signal)
      return signal.isRefusal ? until : nil
    case .probing(let lastUntil):
      // A request admitted before the gate closed: the refusal it carries is already counted.
      return signal.isRefusal ? lastUntil : nil
    case .blocked(let until):
      return signal.isRefusal ? until : nil
    }
  }

  // A probe cancelled before GitHub answered settles nothing: hand the probe to a waiter, or let the
  // next request become it.
  func abandon(_ ticket: Ticket) {
    guard ticket.isProbe, case .probing(let lastUntil) = phase else {
      return
    }
    if waiters.isEmpty {
      phase = .blocked(until: lastUntil)
    } else {
      waiters.removeFirst().resume(returning: .success(Ticket(isProbe: true)))
    }
  }

  private func reopen() {
    phase = .open
    consecutiveRefusals = 0
    let admitted = waiters
    waiters.removeAll()
    for waiter in admitted {
      waiter.resume(returning: .success(Ticket(isProbe: false)))
    }
  }

  private func block(for signal: GithubRateLimitSignal) -> Date {
    let current = now()
    let until: Date
    if let retryAfter = signal.retryAfter {
      until = current.addingTimeInterval(retryAfter.timeInterval)
    } else if let resetAt = signal.resetAt, resetAt > current {
      until = resetAt
    } else {
      consecutiveRefusals += 1
      until = current.addingTimeInterval(
        Self.backoff(afterRefusals: consecutiveRefusals, jitter: jitter()).timeInterval
      )
    }
    phase = .blocked(until: until)
    let refused = waiters
    waiters.removeAll()
    for waiter in refused {
      waiter.resume(returning: .failure(.rateLimited(retryAt: until)))
    }
    return until
  }
}

extension Duration {
  nonisolated fileprivate var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
