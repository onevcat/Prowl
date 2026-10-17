import Foundation

/// Parses the framed output of `RemoteProbeScript` (docs-ai 082, C6).
///
/// Only a report with a matching header, the host record, well-formed records, and an
/// `END` record whose counts match is complete. Anything else is partial, and a partial
/// report never proves that a process is gone.
nonisolated enum RemoteProbeParser {
  enum Result: Equatable, Sendable {
    case complete(RemoteProbeReport)
    case partial(RemoteProbeReport?)
    case unrecognized
  }

  static let formatVersion = "1"

  static func parse(_ text: String) -> Result {
    parse(Data(text.utf8))
  }

  /// Parses raw output. Fields are decoded one by one, so a process whose argv is not
  /// UTF-8 garbles only its own field instead of voiding the snapshot.
  static func parse(_ data: Data) -> Result {
    var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    guard lines.first.map(fields) == ["PROWL-PROBE", formatVersion] else { return .unrecognized }
    var builder = ReportBuilder()
    for line in lines.dropFirst() where !builder.apply(fields(line)) {
      builder.malformed = true
    }
    return builder.result()
  }

  /// Splits a record on TAB and reverses the field escaping.
  static func fields(_ line: Data) -> [String] {
    line.split(separator: UInt8(ascii: "\t"), omittingEmptySubsequences: false).map { decode(unescape($0)) }
  }

  /// Reverses `%XX`; a malformed escape stays literal.
  static func unescape(_ field: Data) -> Data {
    guard field.contains(UInt8(ascii: "%")) else { return field }
    var bytes = Data()
    var iterator = field[...]
    while let byte = iterator.popFirst() {
      if byte == UInt8(ascii: "%"), iterator.count >= 2,
        let hex = String(bytes: iterator.prefix(2), encoding: .ascii), let value = UInt8(hex, radix: 16)
      {
        bytes.append(value)
        iterator = iterator.dropFirst(2)
      } else {
        bytes.append(byte)
      }
    }
    return bytes
  }

  static func unescape(_ field: String) -> String {
    decode(unescape(Data(field.utf8)))
  }

  /// Reverses the display form `lsof` gives a name under `LC_ALL=C`: `\\`, `\t`, `\n`, `\r`,
  /// `\b`, `\f`, `\xNN`, and `^X` for other control characters. A literal `^` before one
  /// of `@A-Z[\]^_` cannot be told apart from a control character and decodes as one.
  static func lsofName(_ text: String) -> String {
    var bytes = Data()
    var iterator = Array(text.utf8)[...]
    let controls: [UInt8: UInt8] = [
      UInt8(ascii: "t"): 0x09, UInt8(ascii: "n"): 0x0A, UInt8(ascii: "r"): 0x0D, UInt8(ascii: "b"): 0x08,
      UInt8(ascii: "f"): 0x0C, UInt8(ascii: "\\"): UInt8(ascii: "\\"),
    ]
    while let byte = iterator.popFirst() {
      switch byte {
      case UInt8(ascii: "\\"):
        if let next = iterator.first, let control = controls[next] {
          bytes.append(control)
          iterator = iterator.dropFirst()
        } else if iterator.first == UInt8(ascii: "x"), iterator.count >= 3,
          let hex = String(bytes: iterator.dropFirst().prefix(2), encoding: .ascii), let value = UInt8(hex, radix: 16)
        {
          bytes.append(value)
          iterator = iterator.dropFirst(3)
        } else {
          bytes.append(byte)
        }
      case UInt8(ascii: "^"):
        if let next = iterator.first, (0x40...0x5F).contains(next) {
          bytes.append(next - 0x40)
          iterator = iterator.dropFirst()
        } else {
          bytes.append(byte)
        }
      default:
        bytes.append(byte)
      }
    }
    return decode(bytes)
  }

  /// UTF-8 when valid; otherwise Latin-1, which maps every byte, so the record survives.
  private static func decode(_ bytes: Data) -> String {
    String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
  }

  fileprivate static func process(_ record: [String]) -> ProcessBuilder? {
    guard record.count == 10, let pid = Int32(record[2]), let ppid = Int32(record[3]),
      let pgid = Int32(record[4]), let elapsed = Int(record[6])
    else { return nil }
    let arguments: [String]?
    let commandLine: String
    switch record[8] {
    case "v":
      let vector = record[9].split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
      arguments = vector
      commandLine = vector.joined(separator: " ")
    case "s":
      arguments = nil
      commandLine = record[9]
    default:
      return nil
    }
    return ProcessBuilder(
      pid: pid, parentPID: ppid, processGroupID: pgid, startToken: record[5], elapsedSeconds: elapsed,
      name: record[7], arguments: arguments, commandLine: commandLine)
  }

  fileprivate struct ProcessBuilder {
    let pid: Int32
    let parentPID: Int32
    let processGroupID: Int32
    let startToken: String
    let elapsedSeconds: Int
    let name: String
    let arguments: [String]?
    let commandLine: String
    var workingDirectory: String?

    func build() -> RemoteProbeProcess {
      RemoteProbeProcess(
        pid: pid, parentPID: parentPID, processGroupID: processGroupID, startToken: startToken,
        elapsedSeconds: elapsedSeconds, name: name, arguments: arguments, commandLine: commandLine,
        workingDirectory: workingDirectory)
    }
  }

  private struct ReportBuilder {
    var host: (system: RemoteProbeReport.OperatingSystem, bootID: String)?
    var sessions: [SessionBuilder] = []
    var ended: (sessions: Int, processes: Int)?
    var malformed = false

    /// Applies one record; false when it is malformed or out of place.
    mutating func apply(_ record: [String]) -> Bool {
      guard ended == nil else { return false }
      switch record.first {
      case "H": return applyHost(record)
      case "S": return applySession(record)
      case "P":
        guard !sessions.isEmpty, let process = RemoteProbeParser.process(record) else { return false }
        sessions[sessions.count - 1].processes.append(process)
        return true
      case "D": return applyDirectory(record)
      case "END":
        guard record.count == 3, let sessionCount = Int(record[1]), let processCount = Int(record[2]) else {
          return false
        }
        ended = (sessionCount, processCount)
        return true
      default: return false
      }
    }

    private mutating func applyHost(_ record: [String]) -> Bool {
      guard host == nil, record.count == 3, let system = RemoteProbeReport.OperatingSystem(rawValue: record[1]),
        record[2] != "-"
      else { return false }
      host = (system, record[2])
      return true
    }

    private mutating func applySession(_ record: [String]) -> Bool {
      guard record.count == 5, let anchor = Int32(record[2]), let tpgid = Int32(record[4]) else { return false }
      sessions.append(
        SessionBuilder(
          paneID: UUID(uuidString: record[1]), anchorPID: anchor, tty: record[3] == "-" ? nil : record[3],
          foregroundProcessGroupID: tpgid))
      return true
    }

    private mutating func applyDirectory(_ record: [String]) -> Bool {
      guard record.count == 5, let pid = Int32(record[2]), !sessions.isEmpty,
        let index = sessions[sessions.count - 1].processes.lastIndex(where: { $0.pid == pid })
      else { return false }
      let path: String
      switch record[3] {
      case "r": path = record[4]
      case "l": path = RemoteProbeParser.lsofName(record[4])
      default: return false
      }
      sessions[sessions.count - 1].processes[index].workingDirectory = path
      return true
    }

    func result() -> Result {
      guard let host else { return .partial(nil) }
      let report = RemoteProbeReport(
        operatingSystem: host.system, bootID: host.bootID, sessions: sessions.map { $0.build() })
      guard !malformed, let ended, ended.sessions == sessions.count,
        ended.processes == sessions.reduce(0, { $0 + $1.processes.count })
      else { return .partial(report) }
      return .complete(report)
    }
  }

  private struct SessionBuilder {
    let paneID: UUID?
    let anchorPID: Int32
    let tty: String?
    let foregroundProcessGroupID: Int32
    var processes: [ProcessBuilder] = []

    func build() -> RemoteProbeSession {
      RemoteProbeSession(
        paneID: paneID, anchorPID: anchorPID, tty: tty, foregroundProcessGroupID: foregroundProcessGroupID,
        processes: processes.map { $0.build() })
    }
  }
}
