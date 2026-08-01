import Foundation
import Testing

@testable import supacode

actor LineChangesShellCallStore {
  private(set) var calls: [[String]] = []

  func record(_ arguments: [String]) {
    calls.append(arguments)
  }
}

struct GitClientLineChangesTests {
  @Test func lineChangesUsesShortstatAndParsesOutput() async throws {
    let store = LineChangesShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        if arguments.contains("--shortstat") {
          return ShellOutput(
            stdout: " 1 file changed, 12 insertions(+), 3 deletions(-)\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 12)
    #expect(changes?.removed == 3)
    let calls = await store.calls
    #expect(calls.count == 2)
    let diffArgs = try #require(calls.first { $0.contains("--shortstat") })
    #expect(diffArgs.first == "git")
    #expect(diffArgs.contains("diff"))
    #expect(diffArgs.contains("HEAD"))
    #expect(!diffArgs.contains("--numstat"))
    let untrackedArgs = try #require(calls.first { $0.contains("ls-files") })
    #expect(untrackedArgs.contains("--others"))
    #expect(untrackedArgs.contains("--exclude-standard"))
    #expect(untrackedArgs.contains("-z"))
  }

  @Test func lineChangesHandlesMissingDeletions() async {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("--shortstat") {
          return ShellOutput(stdout: " 1 file changed, 5 insertions(+)\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 5)
    #expect(changes?.removed == 0)
  }

  @Test func lineChangesParsesShortstatLine() async {
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("--shortstat") {
          return ShellOutput(
            stdout: "1 file changed, 10 insertions(+), 4 deletions(-)\n", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 10)
    #expect(changes?.removed == 4)
  }

  @Test func lineChangesHandlesEmptyOutput() async {
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "\n", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(changes?.added == 0)
    #expect(changes?.removed == 0)
  }

  @Test func lineChangesIncludesUntrackedFileLines() async throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)

    let untrackedFile = tempRoot.appending(path: "new_file.swift")
    try "line1\nline2\nline3\n".write(to: untrackedFile, atomically: true, encoding: .utf8)

    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("--shortstat") {
          return ShellOutput(
            stdout: " 1 file changed, 10 insertions(+), 2 deletions(-)\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("ls-files") {
          return ShellOutput(stdout: "new_file.swift\0", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: tempRoot)

    #expect(changes?.added == 13)
    #expect(changes?.removed == 2)
  }

  @Test func lineChangesSkipsBinaryUntrackedFiles() async throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)

    let binaryFile = tempRoot.appending(path: "image.png")
    var binaryData = Data("PNG\n".utf8)
    binaryData.append(0x00)
    binaryData.append(contentsOf: Data(repeating: 0x0A, count: 100))
    try binaryData.write(to: binaryFile)

    let textFile = tempRoot.appending(path: "readme.txt")
    try "hello\nworld\n".write(to: textFile, atomically: true, encoding: .utf8)

    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("--shortstat") {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        if arguments.contains("ls-files") {
          return ShellOutput(stdout: "image.png\0readme.txt\0", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: tempRoot)

    #expect(changes?.added == 2)
    #expect(changes?.removed == 0)
  }

  @Test func lineChangesParsesNULSeparatedUntrackedFilePaths() async throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)

    let relativePath = " leading space\nname.txt"
    try "alpha\nbeta".write(to: tempRoot.appending(path: relativePath), atomically: true, encoding: .utf8)

    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains("--shortstat") {
          return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }
        if arguments.contains("ls-files") {
          return ShellOutput(stdout: "\(relativePath)\0", stderr: "", exitCode: 0)
        }
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: tempRoot)

    #expect(changes?.added == 2)
    #expect(changes?.removed == 0)
  }

  @Test func lineChangesSkipsWhenIndexLocked() async throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)
    let lockURL = gitDirectory.appending(path: "index.lock")
    try Data().write(to: lockURL)
    let store = LineChangesShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let changes = await client.lineChanges(at: tempRoot)

    #expect(changes == nil)
    let calls = await store.calls
    #expect(calls.isEmpty)
  }

  @Test func indexEntryCountReadsGitIndexHeader() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)

    try writeGitIndexHeader(entryCount: 42_000, to: gitDirectory.appending(path: "index"))

    let count = GitClient.indexEntryCount(at: tempRoot)
    #expect(count == 42_000)
  }

  @Test func indexEntryCountRejectsInvalidHeader() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let gitDirectory = tempRoot.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)

    var invalidMagic = Data()
    invalidMagic.append(contentsOf: "NOPE".utf8)
    invalidMagic.append(contentsOf: [0, 0, 0, 2])
    invalidMagic.append(contentsOf: [0, 0, 0, 1])
    try invalidMagic.write(to: gitDirectory.appending(path: "index"))

    #expect(GitClient.indexEntryCount(at: tempRoot) == nil)

    try writeGitIndexHeader(version: 99, entryCount: 1, to: gitDirectory.appending(path: "index"))

    #expect(GitClient.indexEntryCount(at: tempRoot) == nil)
  }

  @Test func indexEntryCountReturnsNilForMissingIndex() {
    let count = GitClient.indexEntryCount(at: URL(fileURLWithPath: "/nonexistent"))
    #expect(count == nil)
  }

  @Test func countLinesInFilesCountsNewlines() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "a\nb\nc\n".write(to: tempRoot.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    try "x\ny\n".write(to: tempRoot.appending(path: "b.txt"), atomically: true, encoding: .utf8)

    let count = GitClient.countLinesInFiles(["a.txt", "b.txt"], relativeTo: tempRoot).lines
    #expect(count == 5)
  }

  @Test func countLinesInFilesCountsFinalLineWithoutTrailingNewline() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "hello".write(to: tempRoot.appending(path: "single.txt"), atomically: true, encoding: .utf8)
    try "a\nb".write(to: tempRoot.appending(path: "multi.txt"), atomically: true, encoding: .utf8)

    let count = GitClient.countLinesInFiles(["single.txt", "multi.txt"], relativeTo: tempRoot).lines
    #expect(count == 3)
  }

  @Test func countLinesInFilesSkipsBinaryFiles() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "text\nfile\n".write(to: tempRoot.appending(path: "ok.txt"), atomically: true, encoding: .utf8)
    var binary = Data("header\n".utf8)
    binary.append(0x00)
    binary.append(contentsOf: Data(repeating: 0x0A, count: 50))
    try binary.write(to: tempRoot.appending(path: "img.bin"))

    let count = GitClient.countLinesInFiles(["ok.txt", "img.bin"], relativeTo: tempRoot).lines
    #expect(count == 2)
  }

  /// The former per-file cutoff silently hid readable text changes. A file at
  /// that boundary must remain exact when the refresh-wide budget allows it.
  @Test func countLinesInFilesCountsFilesAtTheLegacyByteLimit() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "a\nb\n".write(to: tempRoot.appending(path: "small.txt"), atomically: true, encoding: .utf8)
    let legacyLimit = 2 * 1_024 * 1_024
    // Text, not binary: every newline must contribute to the visible badge.
    let largeText = Data(repeating: 0x0A, count: legacyLimit)
    try largeText.write(to: tempRoot.appending(path: "sample.txt"))

    let count = GitClient.countLinesInFiles(
      ["small.txt", "sample.txt"],
      relativeTo: tempRoot,
      byteBudget: legacyLimit + 16
    ).lines
    #expect(count == legacyLimit + 2)
  }

  /// Keep coverage on both sides of the removed cutoff so a future optimization
  /// cannot accidentally reintroduce the old discontinuity.
  @Test func countLinesInFilesCountsJustUnderTheLegacyByteLimit() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let legacyLimit = 2 * 1_024 * 1_024
    let justUnder = Data(repeating: 0x0A, count: legacyLimit - 1)
    try justUnder.write(to: tempRoot.appending(path: "big.txt"))

    let count = GitClient.countLinesInFiles(["big.txt"], relativeTo: tempRoot).lines
    #expect(count == legacyLimit - 1)
  }

  @Test func countLinesInFilesSkipsMissingFiles() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "a\nb\n".write(to: tempRoot.appending(path: "exists.txt"), atomically: true, encoding: .utf8)

    let count = GitClient.countLinesInFiles(["exists.txt", "gone.txt"], relativeTo: tempRoot).lines
    #expect(count == 2)
  }

  /// The reader works in 64 KiB chunks, so a scan that resumed from the wrong offset
  /// after a hit — or restarted per chunk — would miscount only once a file is larger
  /// than one chunk. Every other case in this file fits in a single chunk.
  @Test func countLinesInFilesCountsAcrossChunkBoundaries() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    // 40_000 lines of "line\n" is ~200 KB, spanning four chunks.
    let content = String(repeating: "line\n", count: 40_000)
    try content.write(to: tempRoot.appending(path: "big.txt"), atomically: true, encoding: .utf8)

    #expect(GitClient.countLinesInFiles(["big.txt"], relativeTo: tempRoot).lines == 40_000)
  }

  /// A newline landing on the final byte of a chunk is the boundary case: the scan must
  /// neither drop it nor double-count it against the next chunk's first byte.
  @Test func countLinesInFilesCountsANewlineOnTheChunkBoundary() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let chunkByteCount = 64 * 1_024
    var bytes = Data(repeating: UInt8(ascii: "a"), count: chunkByteCount - 1)
    bytes.append(0x0A)  // exactly the last byte of chunk one
    bytes.append(contentsOf: Data("second\n".utf8))
    try bytes.write(to: tempRoot.appending(path: "boundary.txt"))

    #expect(GitClient.countLinesInFiles(["boundary.txt"], relativeTo: tempRoot).lines == 2)
  }

  /// Binary detection probes only the first 8 KiB. A NUL past that window has always
  /// been counted as text, and the faster scan must not widen the probe by accident.
  @Test func countLinesInFilesTreatsALateNULAsText() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    var bytes = Data(repeating: UInt8(ascii: "a"), count: 10_000)
    bytes.append(0x00)  // beyond the 8 KiB probe
    bytes.append(0x0A)
    try bytes.write(to: tempRoot.appending(path: "late-nul.txt"))

    #expect(GitClient.countLinesInFiles(["late-nul.txt"], relativeTo: tempRoot).lines == 1)
  }

  @Test func countLinesInFilesCountsAnEmptyFileAsZero() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try Data().write(to: tempRoot.appending(path: "empty.txt"))

    #expect(GitClient.countLinesInFiles(["empty.txt"], relativeTo: tempRoot).lines == 0)
  }

  @Test func countLinesInFilesReusesCachedCountsWithoutSpendingTheRefreshBudget() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "a\nb\n".write(to: tempRoot.appending(path: "cached.txt"), atomically: true, encoding: .utf8)
    let cache = UntrackedLineCountCache()

    let cold = GitClient.countLinesInFiles(
      ["cached.txt"],
      relativeTo: tempRoot,
      cache: cache,
      byteBudget: 4
    )
    let warm = GitClient.countLinesInFiles(
      ["cached.txt"],
      relativeTo: tempRoot,
      cache: cache,
      byteBudget: 0
    )

    #expect(cold == UntrackedLineCountResult(lines: 2, skippedFileCount: 0))
    #expect(warm == cold)
  }

  @Test func countLinesInFilesInvalidatesCachedCountsWhenTheFileChanges() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let fileURL = tempRoot.appending(path: "changing.txt")
    try "a\nb\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let cache = UntrackedLineCountCache()

    let initial = GitClient.countLinesInFiles(
      ["changing.txt"],
      relativeTo: tempRoot,
      cache: cache,
      byteBudget: 4
    )
    try "a\nb\nc\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let invalidated = GitClient.countLinesInFiles(
      ["changing.txt"],
      relativeTo: tempRoot,
      cache: cache,
      byteBudget: 0
    )

    #expect(initial == UntrackedLineCountResult(lines: 2, skippedFileCount: 0))
    #expect(invalidated == UntrackedLineCountResult(lines: 0, skippedFileCount: 1))
  }

  @Test func countLinesInFilesAppliesOneBudgetAcrossAllCacheMisses() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "a\n".write(to: tempRoot.appending(path: "small.txt"), atomically: true, encoding: .utf8)
    try "b\nc\n".write(to: tempRoot.appending(path: "large.txt"), atomically: true, encoding: .utf8)

    let result = GitClient.countLinesInFiles(
      ["large.txt", "small.txt"],
      relativeTo: tempRoot,
      cache: UntrackedLineCountCache(),
      byteBudget: 2
    )

    #expect(result == UntrackedLineCountResult(lines: 1, skippedFileCount: 1))
  }

  @Test func countLinesInFilesBoundsCachedWorktreeLifetime() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let firstRoot = tempRoot.appending(path: "first", directoryHint: .isDirectory)
    let secondRoot = tempRoot.appending(path: "second", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    try "a\n".write(to: firstRoot.appending(path: "file.txt"), atomically: true, encoding: .utf8)
    try "b\n".write(to: secondRoot.appending(path: "file.txt"), atomically: true, encoding: .utf8)
    let cache = UntrackedLineCountCache(maximumWorktreeCount: 1)

    _ = GitClient.countLinesInFiles(
      ["file.txt"], relativeTo: firstRoot, cache: cache, byteBudget: 2)
    _ = GitClient.countLinesInFiles(
      ["file.txt"], relativeTo: secondRoot, cache: cache, byteBudget: 2)
    let evicted = GitClient.countLinesInFiles(
      ["file.txt"], relativeTo: firstRoot, cache: cache, byteBudget: 0)

    #expect(evicted == UntrackedLineCountResult(lines: 0, skippedFileCount: 1))
  }

  @Test func countLinesInFilesBoundsCachedEntriesPerWorktree() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "a\n".write(to: tempRoot.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    try "b\n".write(to: tempRoot.appending(path: "b.txt"), atomically: true, encoding: .utf8)
    let cache = UntrackedLineCountCache(
      maximumWorktreeCount: 1,
      maximumEntryCountPerWorktree: 1,
      maximumTotalEntryCount: 2,
      maximumCachedPathByteCount: 128
    )

    _ = GitClient.countLinesInFiles(
      ["a.txt", "b.txt"], relativeTo: tempRoot, cache: cache, byteBudget: 4)
    let capped = GitClient.countLinesInFiles(
      ["a.txt", "b.txt"], relativeTo: tempRoot, cache: cache, byteBudget: 0)

    #expect(capped == UntrackedLineCountResult(lines: 1, skippedFileCount: 1))
  }

  @Test func countLinesInFilesBoundsCachedEntriesAcrossWorktrees() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    let firstRoot = tempRoot.appending(path: "first", directoryHint: .isDirectory)
    let secondRoot = tempRoot.appending(path: "second", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    try "a\n".write(to: firstRoot.appending(path: "file.txt"), atomically: true, encoding: .utf8)
    try "b\n".write(to: secondRoot.appending(path: "file.txt"), atomically: true, encoding: .utf8)
    let cache = UntrackedLineCountCache(
      maximumWorktreeCount: 2,
      maximumEntryCountPerWorktree: 2,
      maximumTotalEntryCount: 1,
      maximumCachedPathByteCount: 128
    )

    _ = GitClient.countLinesInFiles(
      ["file.txt"], relativeTo: firstRoot, cache: cache, byteBudget: 2)
    _ = GitClient.countLinesInFiles(
      ["file.txt"], relativeTo: secondRoot, cache: cache, byteBudget: 2)
    let capped = GitClient.countLinesInFiles(
      ["file.txt"], relativeTo: firstRoot, cache: cache, byteBudget: 0)

    #expect(capped == UntrackedLineCountResult(lines: 0, skippedFileCount: 1))
  }

  @Test func countLinesInFilesBoundsCachedPathBytes() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "a\n".write(to: tempRoot.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    try "b\n".write(to: tempRoot.appending(path: "b.txt"), atomically: true, encoding: .utf8)
    let cache = UntrackedLineCountCache(
      maximumWorktreeCount: 1,
      maximumEntryCountPerWorktree: 2,
      maximumTotalEntryCount: 2,
      maximumCachedPathByteCount: 9
    )

    _ = GitClient.countLinesInFiles(
      ["a.txt", "b.txt"], relativeTo: tempRoot, cache: cache, byteBudget: 4)
    let capped = GitClient.countLinesInFiles(
      ["a.txt", "b.txt"], relativeTo: tempRoot, cache: cache, byteBudget: 0)

    #expect(capped == UntrackedLineCountResult(lines: 1, skippedFileCount: 1))
  }

  @Test func countLinesInFilesSupportsConcurrentRefreshes() async throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? fileManager.removeItem(at: tempRoot) }
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try "a\nb\n".write(to: tempRoot.appending(path: "shared.txt"), atomically: true, encoding: .utf8)
    let cache = UntrackedLineCountCache()

    let results = await withTaskGroup(of: UntrackedLineCountResult.self) { group in
      for _ in 0..<16 {
        group.addTask {
          GitClient.countLinesInFiles(
            ["shared.txt"], relativeTo: tempRoot, cache: cache, byteBudget: 4)
        }
      }
      var results: [UntrackedLineCountResult] = []
      for await result in group {
        results.append(result)
      }
      return results
    }

    #expect(results.count == 16)
    #expect(results.allSatisfy { $0 == UntrackedLineCountResult(lines: 2, skippedFileCount: 0) })
  }

  private func writeGitIndexHeader(
    version: UInt32 = 2,
    entryCount: UInt32,
    to url: URL
  ) throws {
    var header = Data()
    header.append(contentsOf: "DIRC".utf8)
    header.append(UInt8((version >> 24) & 0xff))
    header.append(UInt8((version >> 16) & 0xff))
    header.append(UInt8((version >> 8) & 0xff))
    header.append(UInt8(version & 0xff))
    header.append(UInt8((entryCount >> 24) & 0xff))
    header.append(UInt8((entryCount >> 16) & 0xff))
    header.append(UInt8((entryCount >> 8) & 0xff))
    header.append(UInt8(entryCount & 0xff))
    try header.write(to: url)
  }
}
