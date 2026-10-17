import Foundation
import Testing

@testable import Prowl

/// The probe wire format (docs-ai 082, C6) against output recorded on real hosts.
struct RemoteProbeParserTests {
  /// Recorded on a macOS 26.5 host (OpenSSH 10.3): Codex and Claude Code started by
  /// `ssh -tt host 'cd /tmp && exec "$SHELL" -lc <agent>'` with distinct pane ids.
  nonisolated static let macOSAgents =
    [
      "PROWL-PROBE\t1",
      "H\tDarwin\t1783703386.707560",
      "S\t22222222-2222-4222-8222-222222222222\t59282\t/dev/ttys000\t59282",
      "P\t22222222-2222-4222-8222-222222222222\t59282\t59281\t59282\tSat Oct 17 20:50:38 2026\t20\tcodex\ts\tcodex",
      "D\t22222222-2222-4222-8222-222222222222\t59282\tl\t/private/tmp",
      "S\t11111111-1111-4111-8111-111111111111\t59286\t/dev/ttys001\t59286",
      "P\t11111111-1111-4111-8111-111111111111\t59286\t59284\t59286\tSat Oct 17 20:50:38 2026\t20\t2.1.302\ts\tclaude",
      "D\t11111111-1111-4111-8111-111111111111\t59286\tl\t/private/tmp",
      "END\t2\t2",
    ].joined(separator: "\n") + "\n"

  /// Recorded in a Debian trixie container (OpenSSH 10.0p2). The second session runs
  /// `exec -a claude sleep 30` in a directory whose name holds a space, a tab, and `%`.
  nonisolated static let linux =
    [
      "PROWL-PROBE\t1",
      "H\tLinux\td8e2436d-c605-4e3b-92d7-57b6424c1e78",
      "S\t44444444-4444-4444-8444-444444444444\t179\t/dev/pts/1\t179",
      "P\t44444444-4444-4444-8444-444444444444\t179\t178\t179\t29059914\t3\tsleep\tv\tsleep\u{1F}25",
      "D\t44444444-4444-4444-8444-444444444444\t179\tr\t/home/dev",
      "S\t33333333-3333-4333-8333-333333333333\t123\t/dev/pts/0\t123",
      "P\t33333333-3333-4333-8333-333333333333\t123\t116\t123\t29057954\t22\tsleep\tv\tclaude\u{1F}30",
      "D\t33333333-3333-4333-8333-333333333333\t123\tr\t/tmp/odd dir/t%09ab%25x",
      "END\t2\t2",
    ].joined(separator: "\n") + "\n"

  private static let mini = ConnectionKey(user: "onevcat", hostname: "mini.local")

  private func report(_ text: String) throws -> RemoteProbeReport {
    guard case .complete(let report) = RemoteProbeParser.parse(text) else {
      Issue.record("expected a complete report")
      throw CancellationError()
    }
    return report
  }

  @Test func macOSRecordingIdentifiesBothAgentsWithRemoteReferences() throws {
    let report = try report(Self.macOSAgents)
    #expect(report.operatingSystem == .darwin)
    #expect(report.bootID == "1783703386.707560")
    #expect(
      report.sessions.map(\.paneID?.uuidString) == [
        "22222222-2222-4222-8222-222222222222", "11111111-1111-4111-8111-111111111111",
      ])

    let codex = try #require(report.sessions[0].foregroundJob(connection: Self.mini, bootID: report.bootID))
    let claude = try #require(report.sessions[1].foregroundJob(connection: Self.mini, bootID: report.bootID))
    let identifiedCodex = try #require(identifyAgentInJob(codex))
    let identifiedClaude = try #require(identifyAgentInJob(claude))
    #expect(identifiedCodex.agent == .codex)
    // The native binary's comm is its version; argv identifies it.
    #expect(identifiedClaude.agent == .claude)
    #expect(identifiedClaude.process.name == "2.1.302")
    #expect(
      identifiedClaude.process.ref
        == .remote(
          RemoteProcessRef(
            connection: Self.mini, bootID: "1783703386.707560", pid: 59286, startToken: "Sat Oct 17 20:50:38 2026")))
    #expect(identifiedClaude.local == nil)
    #expect(report.sessions[1].processes.first?.workingDirectory == "/private/tmp")
    // macOS reports a joined command line only.
    #expect(report.sessions[1].processes.first?.arguments == nil)
  }

  @Test func linuxRecordingKeepsArgumentVectorsAndEscapedFields() throws {
    let report = try report(Self.linux)
    #expect(report.operatingSystem == .linux)
    let session = report.sessions[1]
    #expect(session.tty == "/dev/pts/0")
    let process = try #require(session.processes.first)
    #expect(process.arguments == ["claude", "30"])
    #expect(process.startToken == "29057954")
    #expect(process.workingDirectory == "/tmp/odd dir/t\tab%x")
    let job = try #require(session.foregroundJob(connection: Self.mini, bootID: report.bootID))
    #expect(identifyAgentInJob(job)?.agent == .claude)
    #expect(
      identifyAgentInJob(try #require(report.sessions[0].foregroundJob(connection: Self.mini, bootID: "b"))) == nil)
  }

  @Test func missingOrMismatchedEndRecordIsPartial() {
    let lines = Self.linux.split(separator: "\n").map(String.init)
    let truncated = lines.dropLast().joined(separator: "\n") + "\n"
    guard case .partial(let partial) = RemoteProbeParser.parse(truncated) else {
      Issue.record("expected partial")
      return
    }
    #expect(partial?.sessions.count == 2)

    let mismatched = (lines.dropLast() + ["END\t2\t3"]).joined(separator: "\n")
    guard case .partial = RemoteProbeParser.parse(mismatched) else {
      Issue.record("expected partial")
      return
    }
  }

  @Test func malformedRecordsMakeTheReportPartial() {
    let malformed = [
      "PROWL-PROBE\t1", "H\tLinux\tboot", "S\t-\t10\t/dev/pts/0\t10",
      "P\t-\t10\t9\t10\tstart\tnot-a-number\tbash\tv\tbash", "END\t1\t0",
    ].joined(separator: "\n")
    guard case .partial = RemoteProbeParser.parse(malformed) else {
      Issue.record("expected partial")
      return
    }
    let trailing = Self.linux + "S\t-\t1\t-\t1\n"
    guard case .partial = RemoteProbeParser.parse(trailing) else {
      Issue.record("a record after END is not trusted")
      return
    }
  }

  @Test func aNonUTF8FieldGarblesOnlyItself() throws {
    var data = Data(
      "PROWL-PROBE\t1\nH\tLinux\tb\nS\t-\t10\t/dev/pts/0\t10\nP\t-\t10\t9\t10\t5\t1\tbash\tv\tbash\u{1F}".utf8)
    data.append(contentsOf: [0xFF, 0xFE])
    data.append(Data("\nEND\t1\t1\n".utf8))
    guard case .complete(let report) = RemoteProbeParser.parse(data) else {
      Issue.record("expected complete")
      return
    }
    #expect(report.sessions.first?.processes.first?.arguments == ["bash", "\u{FF}\u{FE}"])
  }

  @Test func lsofNamesDecodeToTheRealPath() {
    // `lsof -Fn` under LC_ALL=C on macOS 26.5 for `/tmp/a<TAB>b\c^d%e 中文`, `nl<LF>x`,
    // and `x<0x01>y<CR>z<ESC>w<DEL>v<BS>u<FF>q`.
    #expect(
      RemoteProbeParser.lsofName(#"/tmp/a\tb\\c^d%e \xe4\xb8\xad\xe6\x96\x87"#) == "/tmp/a\tb\\c^d%e 中文")
    #expect(RemoteProbeParser.lsofName(#"/tmp/nl\nx"#) == "/tmp/nl\nx")
    #expect(
      RemoteProbeParser.lsofName(#"/tmp/x^Ay\rz^[w\x7fv\bu\fq"#) == "/tmp/x\u{1}y\rz\u{1B}w\u{7F}v\u{8}u\u{C}q")
    // Recorded over ssh for a shell in `/tmp/中文 \x<TAB>y`.
    #expect(
      RemoteProbeParser.lsofName(#"/private/tmp/\xe4\xb8\xad\xe6\x96\x87 \\x\ty"#) == "/private/tmp/中文 \\x\ty")
    // An unknown escape stays literal.
    #expect(RemoteProbeParser.lsofName(#"a\qb"#) == #"a\qb"#)
  }

  @Test func directoryEncodingIsChecked() {
    let base = ["PROWL-PROBE\t1", "H\tDarwin\tb", "S\t-\t10\t/dev/ttys000\t10", "P\t-\t10\t9\t10\ts\t1\tzsh\ts\tzsh"]
    let lsof = (base + ["D\t-\t10\tl\t" + #"/Users/me/\xe4\xb8\xad"#, "END\t1\t1"]).joined(separator: "\n")
    guard case .complete(let report) = RemoteProbeParser.parse(lsof) else {
      Issue.record("expected complete")
      return
    }
    #expect(report.sessions.first?.processes.first?.workingDirectory == "/Users/me/中")
    let unknown = (base + ["D\t-\t10\tq\t/x", "END\t1\t1"]).joined(separator: "\n")
    guard case .partial = RemoteProbeParser.parse(unknown) else {
      Issue.record("expected partial")
      return
    }
  }

  @Test func foreignOutputIsUnrecognized() {
    #expect(RemoteProbeParser.parse("") == .unrecognized)
    #expect(RemoteProbeParser.parse("Welcome to the host!\nPROWL-PROBE\t1\n") == .unrecognized)
    #expect(RemoteProbeParser.parse("PROWL-PROBE\t2\nH\tLinux\tb\nEND\t0\t0\n") == .unrecognized)
  }

  @Test func unescapeReversesTheProbeEscapes() {
    #expect(RemoteProbeParser.unescape("a%09b%0Ac%0Dd%25e") == "a\tb\nc\rd%e")
    // Malformed escapes stay literal.
    #expect(RemoteProbeParser.unescape("100%") == "100%")
    #expect(RemoteProbeParser.unescape("%zz") == "%zz")
  }

  @Test func scriptRunsOnThisMacAndProducesACompleteReport() throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-s"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(RemoteProbeScript.text.utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let report = try report(String(bytes: data, encoding: .utf8) ?? "")
    #expect(report.operatingSystem == .darwin)
    #expect(!report.bootID.isEmpty)
  }
}
