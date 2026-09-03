import Foundation
import Testing

@testable import supacode

struct CLIInstallClientTests {
  private func makeTempDir() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("prowl-cli-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  @Test func onlyALiveProwlIsUsable() {
    #expect(CLIInstallStatus.installed(path: "/usr/local/bin/prowl").isUsable)
    #expect(CLIInstallStatus.installedDifferentSource(path: "/usr/local/bin/prowl", destination: "/other").isUsable)
    #expect(CLIInstallStatus.installedDifferentSource(path: "/usr/local/bin/prowl", destination: nil).isUsable)
    #expect(!CLIInstallStatus.broken(path: "/usr/local/bin/prowl", destination: "/gone").isUsable)
    #expect(!CLIInstallStatus.notInstalled.isUsable)
  }

  @Test func statusNotInstalledWhenNoFileExists() throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }
    let installPath = tmp.appendingPathComponent("prowl")

    let client = CLIInstallClient.liveValue
    let status = client.installationStatus(installPath)

    #expect(status == .notInstalled)
  }

  @Test func statusInstalledWhenSymlinkPointsToBundle() throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let fakeBundledBinary = tmp.appendingPathComponent("bundled-prowl")
    FileManager.default.createFile(atPath: fakeBundledBinary.path, contents: nil)

    let installPath = tmp.appendingPathComponent("prowl")
    try FileManager.default.createSymbolicLink(
      atPath: installPath.path,
      withDestinationPath: fakeBundledBinary.path
    )

    let client = CLIInstallClient(
      bundledCLIURL: { fakeBundledBinary },
      installationStatus: { path in
        SymlinkInstaller.status(
          linkPath: path.path(percentEncoded: false),
          source: fakeBundledBinary.path(percentEncoded: false)
        )
      },
      install: { _ in },
      uninstall: { _ in }
    )

    let status = client.installationStatus(installPath)
    #expect(status == .installed(path: installPath.path))
  }

  @Test func statusDifferentSourceWhenSymlinkPointsElsewhere() throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let otherBinary = tmp.appendingPathComponent("other-prowl")
    FileManager.default.createFile(atPath: otherBinary.path, contents: nil)

    let installPath = tmp.appendingPathComponent("prowl")
    try FileManager.default.createSymbolicLink(
      atPath: installPath.path,
      withDestinationPath: otherBinary.path
    )

    let client = CLIInstallClient.liveValue
    let status = client.installationStatus(installPath)

    #expect(status == .installedDifferentSource(path: installPath.path, destination: otherBinary.path))
  }

  @Test func statusDifferentSourceWhenRegularFileExists() throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let installPath = tmp.appendingPathComponent("prowl")
    FileManager.default.createFile(atPath: installPath.path, contents: Data("binary".utf8))

    let client = CLIInstallClient.liveValue
    let status = client.installationStatus(installPath)

    #expect(status == .installedDifferentSource(path: installPath.path, destination: nil))
  }

  @Test func statusBrokenWhenSymlinkIsDangling() throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let installPath = tmp.appendingPathComponent("prowl")
    try FileManager.default.createSymbolicLink(
      atPath: installPath.path,
      withDestinationPath: tmp.appendingPathComponent("moved-away").path
    )

    let client = CLIInstallClient.liveValue
    let status = client.installationStatus(installPath)

    #expect(status == .broken(path: installPath.path, destination: tmp.appendingPathComponent("moved-away").path))
  }

  @Test func liveInstallReplacesDanglingSymlinkWithBundledCLI() async throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let installPath = tmp.appendingPathComponent("prowl")
    try FileManager.default.createSymbolicLink(
      atPath: installPath.path,
      withDestinationPath: tmp.appendingPathComponent("moved-away").path
    )

    let client = CLIInstallClient.liveValue
    let bundled = try #require(client.bundledCLIURL())
    try await client.install(installPath)

    let target = try FileManager.default.destinationOfSymbolicLink(atPath: installPath.path)
    #expect(target == bundled.path(percentEncoded: false))
    #expect(client.installationStatus(installPath) == .installed(path: installPath.path))
  }

  @Test func liveUninstallRemovesDanglingSymlink() async throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let installPath = tmp.appendingPathComponent("prowl")
    try FileManager.default.createSymbolicLink(
      atPath: installPath.path,
      withDestinationPath: tmp.appendingPathComponent("moved-away").path
    )

    try await CLIInstallClient.liveValue.uninstall(installPath)

    #expect((try? FileManager.default.attributesOfItem(atPath: installPath.path)) == nil)
  }

  @Test func installCreatesSymlink() async throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let fakeBundled = tmp.appendingPathComponent("source/prowl")
    try FileManager.default.createDirectory(
      at: fakeBundled.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: fakeBundled.path, contents: Data("cli".utf8))

    let installPath = tmp.appendingPathComponent("bin/prowl")
    let client = CLIInstallClient(
      bundledCLIURL: { fakeBundled },
      installationStatus: CLIInstallClient.liveValue.installationStatus,
      install: { path in
        let fileManager = FileManager.default
        let bundledPath = fakeBundled.path(percentEncoded: false)
        let installDir = path.deletingLastPathComponent().path(percentEncoded: false)
        if !fileManager.fileExists(atPath: installDir) {
          try fileManager.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        }
        let destination = path.path(percentEncoded: false)
        if fileManager.fileExists(atPath: destination) {
          try fileManager.removeItem(atPath: destination)
        }
        do {
          try fileManager.createSymbolicLink(atPath: destination, withDestinationPath: bundledPath)
        } catch {
          throw CLIInstallError(message: error.localizedDescription)
        }
      },
      uninstall: CLIInstallClient.liveValue.uninstall
    )

    try await client.install(installPath)

    let fileManager = FileManager.default
    let attrs = try fileManager.attributesOfItem(atPath: installPath.path)
    #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)

    let target = try fileManager.destinationOfSymbolicLink(atPath: installPath.path)
    #expect(target == fakeBundled.path)
  }

  @Test func installCreatesParentDirectoryIfNeeded() async throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let fakeBundled = tmp.appendingPathComponent("source/prowl")
    try FileManager.default.createDirectory(
      at: fakeBundled.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: fakeBundled.path, contents: nil)

    let deepPath = tmp.appendingPathComponent("a/b/c/prowl")
    let client = CLIInstallClient(
      bundledCLIURL: { fakeBundled },
      installationStatus: CLIInstallClient.liveValue.installationStatus,
      install: { path in
        let fileManager = FileManager.default
        let bundledPath = fakeBundled.path(percentEncoded: false)
        let installDir = path.deletingLastPathComponent().path(percentEncoded: false)
        if !fileManager.fileExists(atPath: installDir) {
          try fileManager.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        }
        let destination = path.path(percentEncoded: false)
        do {
          try fileManager.createSymbolicLink(atPath: destination, withDestinationPath: bundledPath)
        } catch {
          throw CLIInstallError(message: error.localizedDescription)
        }
      },
      uninstall: CLIInstallClient.liveValue.uninstall
    )

    try await client.install(deepPath)

    #expect(FileManager.default.fileExists(atPath: deepPath.path))
  }

  @Test func uninstallRemovesSymlink() async throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let target = tmp.appendingPathComponent("target")
    FileManager.default.createFile(atPath: target.path, contents: nil)

    let installPath = tmp.appendingPathComponent("prowl")
    try FileManager.default.createSymbolicLink(
      atPath: installPath.path,
      withDestinationPath: target.path
    )

    let client = CLIInstallClient.liveValue
    try await client.uninstall(installPath)

    #expect(!FileManager.default.fileExists(atPath: installPath.path))
  }

  @Test func uninstallRefusesToRemoveRegularFile() async throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let installPath = tmp.appendingPathComponent("prowl")
    FileManager.default.createFile(atPath: installPath.path, contents: Data("binary".utf8))

    let client = CLIInstallClient.liveValue

    do {
      try await client.uninstall(installPath)
      Issue.record("Expected uninstall to throw for non-symlink file")
    } catch let error as CLIInstallError {
      #expect(error.message.contains("not a symlink"))
    }
    #expect(FileManager.default.fileExists(atPath: installPath.path))
  }

  @Test func installRefusesToOverwriteRegularFile() async throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let fakeBundled = tmp.appendingPathComponent("source/prowl")
    try FileManager.default.createDirectory(
      at: fakeBundled.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: fakeBundled.path, contents: Data("cli".utf8))

    let installPath = tmp.appendingPathComponent("prowl")
    FileManager.default.createFile(atPath: installPath.path, contents: Data("existing".utf8))

    let client = CLIInstallClient.liveValue

    do {
      try await client.install(installPath)
      Issue.record("Expected install to throw for non-symlink target")
    } catch let error as CLIInstallError {
      #expect(error.message.contains("not a symlink"))
    }
    // Original file must be preserved
    let contents = FileManager.default.contents(atPath: installPath.path)
    #expect(contents == Data("existing".utf8))
  }

  @Test func installOverwritesExistingSymlink() async throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let fakeBundled = tmp.appendingPathComponent("source/prowl")
    try FileManager.default.createDirectory(
      at: fakeBundled.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: fakeBundled.path, contents: Data("cli".utf8))

    let oldTarget = tmp.appendingPathComponent("old-prowl")
    FileManager.default.createFile(atPath: oldTarget.path, contents: nil)

    let installPath = tmp.appendingPathComponent("prowl")
    try FileManager.default.createSymbolicLink(
      atPath: installPath.path,
      withDestinationPath: oldTarget.path
    )

    let client = makeTestInstallClient(bundledBinary: fakeBundled)
    try await client.install(installPath)

    let newTarget = try FileManager.default.destinationOfSymbolicLink(atPath: installPath.path)
    #expect(newTarget == fakeBundled.path)
  }

  @Test func uninstallThrowsWhenNoFileExists() async throws {
    let tmp = try makeTempDir()
    defer { cleanup(tmp) }

    let installPath = tmp.appendingPathComponent("prowl")
    let client = CLIInstallClient.liveValue

    do {
      try await client.uninstall(installPath)
      Issue.record("Expected uninstall to throw when file does not exist")
    } catch let error as CLIInstallError {
      #expect(error.message.contains("No CLI tool found"))
    }
  }

  /// Creates a test install client that uses a fake bundled binary path instead of Bundle.main.
  private func makeTestInstallClient(bundledBinary: URL) -> CLIInstallClient {
    CLIInstallClient(
      bundledCLIURL: { bundledBinary },
      installationStatus: CLIInstallClient.liveValue.installationStatus,
      install: { installPath in
        let fileManager = FileManager.default
        let bundledPath = bundledBinary.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: bundledPath) else {
          throw CLIInstallError(message: "Bundled CLI binary not found.")
        }
        let installDir = installPath.deletingLastPathComponent().path(percentEncoded: false)
        if !fileManager.fileExists(atPath: installDir) {
          try fileManager.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        }
        let destination = installPath.path(percentEncoded: false)
        if fileManager.fileExists(atPath: destination) {
          let attrs = try? fileManager.attributesOfItem(atPath: destination)
          let isSymlink = attrs?[.type] as? FileAttributeType == .typeSymbolicLink
          guard isSymlink else {
            throw CLIInstallError(
              message: "A file already exists at \(destination) and is not a symlink."
            )
          }
          try fileManager.removeItem(atPath: destination)
        }
        try fileManager.createSymbolicLink(atPath: destination, withDestinationPath: bundledPath)
      },
      uninstall: CLIInstallClient.liveValue.uninstall
    )
  }
}
