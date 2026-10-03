import ComposableArchitecture
import Foundation

nonisolated struct ExternalDiffToolClient: Sendable {
  var open:
    @MainActor @Sendable (
      _ settings: ExternalDiffSettings,
      _ target: DiffTarget,
      _ resolvedKeybindings: ResolvedKeybindingMap,
      _ onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
    ) async -> Void
}

extension ExternalDiffToolClient: DependencyKey {
  static let liveValue = ExternalDiffToolClient { settings, target, resolvedKeybindings, onError in
    @Dependency(TerminalClient.self) var terminalClient
    @Dependency(ShellClient.self) var shellClient
    @Dependency(ExternalDiffSnapshotClient.self) var snapshotClient
    @Dependency(OutgoingChangesClient.self) var outgoingChangesClient

    switch settings.tool {
    case .builtIn:
      @Shared(.settingsFile) var settingsFile
      DiffWindowManager.shared.show(
        worktreeURL: target.workingDirectory,
        branchName: target.branchName,
        outgoingResolver: outgoingChangesClient.makeResolver(target),
        resolvedKeybindings: resolvedKeybindings,
        colorScheme: settingsFile.global.appearanceMode.colorScheme
      )

    case .hunk:
      // A cwd override means the diff runs somewhere other than the host's own
      // directory (a workspace child); name the tab after that repository.
      let commandName =
        target.terminalWorkingDirectory == nil
        ? "Hunk Diff"
        : "Hunk Diff · \(target.workingDirectory.lastPathComponent)"
      await terminalClient.send(
        .createTabWithInput(
          target.terminalHost,
          input: "hunk diff",
          workingDirectory: target.terminalWorkingDirectory,
          runSetupScriptIfNew: false,
          autoCloseOnSuccess: false,
          customCommandName: commandName,
          customCommandIcon: "square.split.2x1"
        )
      )

    case .fileMerge:
      await runGUICommand(
        ExternalDiffGUICommandRequest(tool: settings.tool, executableName: "opendiff", arguments: []),
        target: target,
        shellClient: shellClient,
        snapshotClient: snapshotClient,
        onError: onError
      )

    case .kaleidoscope:
      await runGUICommand(
        ExternalDiffGUICommandRequest(tool: settings.tool, executableName: "ksdiff", arguments: ["--diff"]),
        target: target,
        shellClient: shellClient,
        snapshotClient: snapshotClient,
        onError: onError
      )

    case .custom:
      await runCustomCommand(
        settings: settings,
        target: target,
        shellClient: shellClient,
        snapshotClient: snapshotClient,
        onError: onError
      )
    }
  }

  static let testValue = ExternalDiffToolClient { _, _, _, _ in }
}

extension DependencyValues {
  var externalDiffToolClient: ExternalDiffToolClient {
    get { self[ExternalDiffToolClient.self] }
    set { self[ExternalDiffToolClient.self] = newValue }
  }
}

private struct ExternalDiffGUICommandRequest {
  let tool: ExternalDiffTool
  let executableName: String
  let arguments: [String]
}

private func runGUICommand(
  _ request: ExternalDiffGUICommandRequest,
  target: DiffTarget,
  shellClient: ShellClient,
  snapshotClient: ExternalDiffSnapshotClient,
  onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
) async {
  do {
    let snapshot = try await snapshotClient.makeSnapshotPair(target.workingDirectory)
    let executableURL = URL(fileURLWithPath: "/usr/bin/env")
    _ = try await shellClient.runLogin(
      executableURL,
      [request.executableName] + request.arguments + [
        snapshot.leftURL.path(percentEncoded: false),
        snapshot.rightURL.path(percentEncoded: false),
      ],
      target.workingDirectory
    )
  } catch {
    onError(openError(for: request.tool, error: error))
  }
}

private func runCustomCommand(
  settings: ExternalDiffSettings,
  target: DiffTarget,
  shellClient: ShellClient,
  snapshotClient: ExternalDiffSnapshotClient,
  onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
) async {
  let template = settings.customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !template.isEmpty else {
    onError(
      OpenActionError(
        title: String(localized: "Custom diff command is empty"),
        message: String(localized: "Add a custom diff command in Settings before opening the diff.")
      )
    )
    return
  }
  do {
    let snapshot = try await snapshotClient.makeSnapshotPair(target.workingDirectory)
    let context = ExternalDiffCommandContext(
      worktreePath: target.workingDirectory.path(percentEncoded: false),
      repoPath: target.repositoryRootURL.path(percentEncoded: false),
      branch: target.branchName,
      leftPath: snapshot.leftURL.path(percentEncoded: false),
      rightPath: snapshot.rightURL.path(percentEncoded: false)
    )
    let command = ExternalDiffCommandTemplate.render(template, context: context)
    _ = try await shellClient.runLogin(
      URL(fileURLWithPath: "/bin/zsh"),
      ["-lc", command],
      target.workingDirectory
    )
  } catch {
    onError(openError(for: settings.tool, error: error))
  }
}

private func openError(for tool: ExternalDiffTool, error: Error) -> OpenActionError {
  OpenActionError(
    title: String(localized: "Unable to open diff in \(tool.title)"),
    message: error.localizedDescription
  )
}
