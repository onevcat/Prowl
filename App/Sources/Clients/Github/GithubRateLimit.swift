import Foundation

// What one gh invocation said about the account's rate limit. A refusal means GitHub turned the
// request away; an exhausted budget means the request succeeded but spent the last of it, so the
// next one would be refused.
nonisolated struct GithubRateLimitSignal: Equatable, Sendable {
  var isRefusal: Bool
  var retryAfter: Duration?
  var retryAfterDate: Date?
  var resetAt: Date?
}

// Reads a rate-limit answer out of gh's output. `gh api --include` prints the response's status line
// and headers ahead of the body; other gh commands report only through stderr.
nonisolated enum GithubRateLimitClassifier {
  static func classify(stdout: String, stderr: String, succeeded: Bool) -> GithubRateLimitSignal? {
    let response = parseResponseHead(stdout)
    let retryAfterField = response.fields["retry-after"]
    let retryAfter = retryAfterField.flatMap(Int.init).map { Duration.seconds($0) }
    let retryAfterDate = retryAfter == nil ? retryAfterField.flatMap(parseHTTPDate) : nil
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
      isRefusal = retryAfterField != nil || budgetExhausted || bodySaysLimited || stderrSaysLimited
    default:
      isRefusal = bodySaysLimited || stderrSaysLimited
    }
    if isRefusal {
      return GithubRateLimitSignal(
        isRefusal: true,
        retryAfter: retryAfter,
        retryAfterDate: retryAfterDate,
        resetAt: resetAt
      )
    }
    if budgetExhausted {
      return GithubRateLimitSignal(
        isRefusal: false,
        retryAfter: retryAfter,
        retryAfterDate: retryAfterDate,
        resetAt: resetAt
      )
    }
    return nil
  }

  // The HTTP status gh printed with `--include`, which shows that GitHub itself answered.
  static func responseStatus(in stdout: String) -> Int? {
    parseResponseHead(stdout).status
  }

  // Retry-After may also be an HTTP date (RFC 9110), such as "Wed, 21 Oct 2026 07:28:00 GMT".
  private static func parseHTTPDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
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
// nothing until the retry time. Then exactly one request goes out as a probe; the others wait for
// GitHub's answer to it instead of racing it.
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

  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Ticket, Error>
  }

  private let now: @Sendable () -> Date
  private let jitter: @Sendable () -> Double
  private var phase: Phase = .open
  private var consecutiveRefusals = 0
  private var waiters: [Waiter] = []
  private var observers: [UUID: AsyncStream<Date?>.Continuation] = [:]

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

  // The retry time while GitHub is refusing the account, nil while requests flow. Each subscriber
  // receives the current value first.
  func retryTimes() -> AsyncStream<Date?> {
    let (stream, continuation) = AsyncStream<Date?>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    observers[id] = continuation
    continuation.onTermination = { _ in
      Task { await self.removeObserver(id) }
    }
    continuation.yield(retryTime)
    return stream
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
      let id = UUID()
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            waiters.append(Waiter(id: id, continuation: continuation))
          }
        }
      } onCancel: {
        Task { await self.cancelWaiter(id) }
      }
    }
  }

  // Records how a ticket's request ended. `answered` means GitHub itself responded: gh succeeded, or
  // its output carries an HTTP status. Returns the retry time when the request must be reported as
  // rate-limited, nil when its own result stands.
  func record(_ ticket: Ticket, signal: GithubRateLimitSignal?, answered: Bool) -> Date? {
    guard let signal else {
      if ticket.isProbe, case .probing = phase {
        if answered {
          reopen()
        } else {
          // A local failure says nothing about GitHub; one more request has to find out.
          handOffProbe()
        }
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

  // A probe cancelled before GitHub answered settles nothing.
  func abandon(_ ticket: Ticket) {
    guard ticket.isProbe, case .probing = phase else {
      return
    }
    handOffProbe()
  }

  private var retryTime: Date? {
    switch phase {
    case .open:
      nil
    case .blocked(let until):
      until
    case .probing(let lastUntil):
      lastUntil
    }
  }

  private func handOffProbe() {
    guard case .probing(let lastUntil) = phase else {
      return
    }
    if waiters.isEmpty {
      phase = .blocked(until: lastUntil)
    } else {
      waiters.removeFirst().continuation.resume(returning: Ticket(isProbe: true))
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      return
    }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  private func removeObserver(_ id: UUID) {
    observers.removeValue(forKey: id)
  }

  private func publish() {
    let value = retryTime
    for observer in observers.values {
      observer.yield(value)
    }
  }

  private func reopen() {
    phase = .open
    consecutiveRefusals = 0
    let admitted = waiters
    waiters.removeAll()
    for waiter in admitted {
      waiter.continuation.resume(returning: Ticket(isProbe: false))
    }
    publish()
  }

  private func block(for signal: GithubRateLimitSignal) -> Date {
    let current = now()
    if signal.isRefusal {
      consecutiveRefusals += 1
    }
    let until: Date
    if let retryAfter = signal.retryAfter {
      until = current.addingTimeInterval(retryAfter.timeInterval)
    } else if let retryAfterDate = signal.retryAfterDate, retryAfterDate > current {
      until = retryAfterDate
    } else if let resetAt = signal.resetAt, resetAt > current {
      until = resetAt
    } else {
      until = current.addingTimeInterval(
        Self.backoff(afterRefusals: max(consecutiveRefusals, 1), jitter: jitter()).timeInterval
      )
    }
    phase = .blocked(until: until)
    let refused = waiters
    waiters.removeAll()
    for waiter in refused {
      waiter.continuation.resume(throwing: GithubCLIError.rateLimited(retryAt: until))
    }
    publish()
    return until
  }
}

extension Duration {
  nonisolated fileprivate var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
