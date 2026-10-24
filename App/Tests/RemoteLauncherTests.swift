import Foundation
import Testing

@testable import Prowl

/// The remote terminal launcher (docs-ai 084 C3a), run against the real shells of this Mac:
/// staging through `sh -s`, the hand-over to the user's login shell, the first command and
/// its completion marker. fish runs where it is installed.
nonisolated struct RemoteLauncherTests {
  /// One launch in a temporary home: the user's startup files log each load.
  private struct Home {
    let root: URL
    let log: URL

    init() throws {
      root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "prowl-launch-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: root.appending(path: "work/sub"), withIntermediateDirectories: true)
      log = root.appending(path: "startup.log")
      let files = [
        ".zshenv": "echo zshenv >> \"$HOME/startup.log\"",
        ".zprofile": "echo zprofile >> \"$HOME/startup.log\"",
        ".zshrc": "echo zshrc >> \"$HOME/startup.log\"",
        ".bash_profile": "echo bash_profile >> \"$HOME/startup.log\"",
        ".config/fish/config.fish": "echo fish_config >> $HOME/startup.log",
      ]
      for (name, text) in files {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((text + "\n").utf8).write(to: url)
      }
    }

    var path: String { root.path(percentEncoded: false).trimmingSuffixSlash }
    var workingDirectory: String { path + "/work" }

    func loads() -> [String] {
      ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  private static let shells = ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/bash", "/opt/homebrew/bin/fish"]
    .filter { FileManager.default.isExecutableFile(atPath: $0) }

  /// Runs `executable` with `arguments`, input on stdin, and a timeout; output joins stdout
  /// and stderr.
  private static func run(
    _ executable: String, _ arguments: [String], input: String, environment: [String: String]
  ) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.environment = environment
    let stdin = Pipe()
    let output = Pipe()
    process.standardInput = stdin
    process.standardOutput = output
    process.standardError = output
    // Read on another thread, and kill the whole run at the deadline: an interactive shell
    // ignores SIGTERM, and a reader that waits for EOF would hang the suite instead of failing.
    let collected = LockedData()
    let reader = Thread {
      while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        collected.append(chunk)
      }
    }
    try process.run()
    reader.start()
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    let deadline = Date().addingTimeInterval(30)
    while process.isRunning, Date() < deadline { usleep(20_000) }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      Issue.record("\(executable) did not finish in time")
    }
    process.waitUntilExit()
    // Children that kept the pipe open cannot hold the test: give the reader a moment only.
    let readDeadline = Date().addingTimeInterval(2)
    while !reader.isFinished, Date() < readDeadline { usleep(20_000) }
    return String(bytes: collected.data, encoding: .utf8) ?? ""
  }

  /// Stages `launch` in `home` as the host would, then runs the launcher with `shell` as the
  /// user's login shell, feeding `input` to the shell.
  private static func launch(
    _ launch: RemoteLaunch, shell: String, home: Home, input: String
  ) throws -> (output: String, launcher: String) {
    let environment = [
      "HOME": home.path, "SHELL": shell, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
      "TERM": "dumb", "LANG": "en_US.UTF-8",
    ]
    let staging = try RemoteLauncher.stagingCommand(for: launch).script()
    let staged = try run("/bin/sh", ["-s"], input: staging, environment: environment)
    let launcher = try RemoteLauncher.stagedLauncherPath(from: staged, for: launch)
    let output = try run("/bin/sh", [launcher], input: input, environment: environment)
    return (output, launcher)
  }

  /// Runs the staged `launch` in a terminal (`script` gives it a controlling PTY), so the
  /// terminal's interrupt character sends SIGINT. Each step waits for its text in the output,
  /// then types its input.
  private static func launchInTerminal(
    _ launch: RemoteLaunch, shell: String, home: Home, steps: [(waitFor: String, send: String)]
  ) throws -> (output: String, launcher: String) {
    let environment = [
      "HOME": home.path, "SHELL": shell, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
      "TERM": "dumb", "LANG": "en_US.UTF-8",
    ]
    let staging = try RemoteLauncher.stagingCommand(for: launch).script()
    let staged = try run("/bin/sh", ["-s"], input: staging, environment: environment)
    let launcher = try RemoteLauncher.stagedLauncherPath(from: staged, for: launch)
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/script")
    process.arguments = ["-q", "/dev/null", "/bin/sh", launcher]
    process.environment = environment
    let stdin = Pipe()
    let output = Pipe()
    process.standardInput = stdin
    process.standardOutput = output
    process.standardError = output
    let collected = LockedData()
    let reader = Thread {
      while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        collected.append(chunk)
      }
    }
    try process.run()
    reader.start()
    let text = { String(bytes: collected.data, encoding: .utf8) ?? "" }
    let deadline = Date().addingTimeInterval(30)
    for step in steps {
      while !text().contains(step.waitFor), process.isRunning, Date() < deadline { usleep(20_000) }
      guard text().contains(step.waitFor) else {
        Issue.record("no \(step.waitFor.debugDescription) in time: \(text().debugDescription)")
        break
      }
      stdin.fileHandleForWriting.write(Data(step.send.utf8))
    }
    while process.isRunning, Date() < deadline { usleep(20_000) }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      Issue.record("\(shell) did not finish in time")
    }
    process.waitUntilExit()
    try? stdin.fileHandleForWriting.close()
    let readDeadline = Date().addingTimeInterval(2)
    while !reader.isFinished, Date() < readDeadline { usleep(20_000) }
    return (text(), launcher)
  }

  private static func marker(_ nonce: String, state: String, status: Int32) -> String {
    "\u{1b}]7501;state=\(state):id=prowl-launch/\(nonce)/\(status)\u{07}"
  }

  /// The first command runs in the user's shell after its startup files, which load once;
  /// its `cd` and exports stay at the prompt; the marker reports success once; a nested
  /// shell does not replay it; the launch directory is gone.
  @Test(arguments: shells)
  func theFirstCommandRunsOnceInTheUsersShellAndItsStateStays(_ shell: String) throws {
    let home = try Home()
    defer { home.remove() }
    let isFish = shell.hasSuffix("fish")
    let command =
      isFish
      ? "cd sub; and set -gx PROWL_TEST 'it''s ✓'"
      : "cd sub && PROWL_TEST=\"it's ✓\" && export PROWL_TEST"
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory,
      environment: [RemoteLaunchVariable(name: "PROWL_WORKTREE_PATH", value: home.workingDirectory)],
      firstCommand: command)
    let input =
      isFish
      ? "echo \"STATE:$PWD:$PROWL_TEST:$PROWL_WORKTREE_PATH:\"(set -q PROWL_LAUNCH_DIR; and echo set; or echo unset)\n"
        + "\(shell) -ic 'echo NESTED'\nexit\n"
      : "echo \"STATE:$PWD:$PROWL_TEST:$PROWL_WORKTREE_PATH:${PROWL_LAUNCH_DIR-unset}\"\n"
        + "\(shell) -ic 'echo NESTED'\nexit\n"

    let (output, launcher) = try Self.launch(launch, shell: shell, home: home, input: input)

    // The shell may report the logical or the physical path of the directory.
    #expect(output.contains("/work/sub:it's ✓:\(home.workingDirectory):unset"), "\(output)")
    #expect(output.components(separatedBy: Self.marker(launch.nonce, state: "done", status: 0)).count == 2, "\(output)")
    #expect(output.contains("NESTED"))
    // The exit report is a no-op after the first command: no leftover error at exit.
    #expect(!output.contains("not found"), "\(output)")
    #expect(!FileManager.default.fileExists(atPath: URL(filePath: launcher).deletingLastPathComponent().path))
    let loads = home.loads()
    switch shell {
    case let zsh where zsh.hasSuffix("zsh"):
      // The nested `zsh -ic` reads .zshenv and .zshrc once more, without the first command.
      #expect(loads.filter { $0 == "zprofile" }.count == 1, "\(loads)")
      #expect(loads.filter { $0 == "zshrc" }.count == 2, "\(loads)")
    case let fish where fish.hasSuffix("fish"):
      #expect(loads.filter { $0 == "fish_config" }.count == 2, "\(loads)")
    default:
      #expect(loads.filter { $0 == "bash_profile" }.count == 1, "\(loads)")
    }
  }

  /// A script arrives byte for byte and runs in the user's shell: zsh's own syntax works.
  @Test func aZshScriptRunsInZsh() throws {
    guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
    let home = try Home()
    defer { home.remove() }
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [],
      firstCommand: "value='a b'\\''c $HOME `x`'\necho \"UPPER:${(U)value}\"\n")

    let (output, _) = try Self.launch(launch, shell: "/bin/zsh", home: home, input: "exit\n")

    #expect(output.contains("UPPER:A B'C $HOME `X`"), "\(output)")
  }

  /// The first command runs after the user's own `precmd` hooks (an instant prompt
  /// captures output until its hook ran), and a `~/.zshenv` that moves `ZDOTDIR` (the XDG
  /// layout) still loads the user's files from there once.
  @Test func zshRunsTheCommandAfterTheUsersHooksAndFollowsAMovedZDOTDIR() throws {
    guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
    let home = try Home()
    defer { home.remove() }
    let xdg = home.root.appending(path: ".config/zsh", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
    try Data("export ZDOTDIR=\"$HOME/.config/zsh\"\necho zshenv >> \"$HOME/startup.log\"\n".utf8)
      .write(to: home.root.appending(path: ".zshenv"))
    try Data(
      """
      echo xdg_zshrc >> "$HOME/startup.log"
      user_hook() { echo user_precmd >> "$HOME/startup.log"; }
      precmd_functions+=(user_hook)

      """.utf8
    ).write(to: xdg.appending(path: ".zshrc"))
    try Data("echo xdg_zlogin >> \"$HOME/startup.log\"\n".utf8).write(to: xdg.appending(path: ".zlogin"))
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [],
      firstCommand: "echo first_command >> \"$HOME/startup.log\"")

    let (output, _) = try Self.launch(
      launch, shell: "/bin/zsh", home: home, input: "echo \"ZD:$ZDOTDIR\"\nexit\n")

    let loads = home.loads()
    #expect(loads.filter { $0 == "xdg_zshrc" }.count == 1, "\(loads)")
    #expect(loads.filter { $0 == "xdg_zlogin" }.count == 1, "\(loads)")
    #expect(loads.filter { $0 == "zshrc" }.isEmpty, "\(loads)")
    let first = try #require(loads.firstIndex(of: "first_command"), "\(loads)")
    let hook = try #require(loads.firstIndex(of: "user_precmd"), "\(loads)")
    #expect(hook < first, "\(loads)")
    #expect(output.contains("ZD:\(home.path)/.config/zsh"), "\(output)")
  }

  /// The user's startup files keep their top-level meaning: a `typeset -U path` change and
  /// an associative array from `.zshrc` stay for the first command and the prompt.
  @Test func zshStartupFilesKeepTheirTopLevelDeclarations() throws {
    guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
    let home = try Home()
    defer { home.remove() }
    try Data(
      """
      typeset -U path PATH
      path=("$HOME/bin" $path)
      typeset -A MY_STYLES
      MY_STYLES[color]=blue

      """.utf8
    ).write(to: home.root.appending(path: ".zshrc"))
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [],
      firstCommand: "echo \"FIRST:${path[1]}:${MY_STYLES[color]}\"")

    let (output, _) = try Self.launch(
      launch, shell: "/bin/zsh", home: home, input: "echo \"PROMPT:${path[1]}:${MY_STYLES[color]}\"\nexit\n")

    #expect(output.contains("FIRST:\(home.path)/bin:blue"), "\(output)")
    #expect(output.contains("PROMPT:\(home.path)/bin:blue"), "\(output)")
  }

  /// A first command that ends the shell still reports its status once: `set -e` with a
  /// failing step, or an explicit `exit`.
  @Test(arguments: shells)
  func aFirstCommandThatEndsTheShellStillReports(_ shell: String) throws {
    let home = try Home()
    defer { home.remove() }
    let commands = shell.hasSuffix("fish") ? ["exit 3"] : ["set -e; echo RAN; false", "exit 3"]
    for command in commands {
      let launch = RemoteLaunch(
        nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [],
        firstCommand: command)

      let (output, launcher) = try Self.launch(launch, shell: shell, home: home, input: "echo SHOULD_NOT_RUN\n")

      let status: Int32 = command.hasPrefix("exit") ? 3 : 1
      let marker = Self.marker(launch.nonce, state: "error", status: status)
      #expect(output.components(separatedBy: marker).count == 2, "\(command): \(output)")
      #expect(!FileManager.default.fileExists(atPath: URL(filePath: launcher).deletingLastPathComponent().path))
    }
  }

  /// The user's own `EXIT` traps are never replaced: a trap from the startup files and one
  /// that the first command sets both run, and the launch reports once either way.
  @Test(arguments: shells.filter { $0.hasSuffix("bash") })
  func bashKeepsTheUsersExitTraps(_ shell: String) throws {
    struct Case {
      let profile: String
      let command: String
      let state: String
      let status: Int32
      let cleanup: String
    }
    let userTrap = "trap 'echo USER_CLEANUP' EXIT"
    let cases = [
      Case(
        profile: userTrap, command: "true", state: "done", status: 0, cleanup: "USER_CLEANUP"),
      Case(
        profile: userTrap, command: "exit 3", state: "error", status: 3, cleanup: "USER_CLEANUP"),
      Case(
        profile: userTrap, command: "set -e; false", state: "error", status: 1,
        cleanup: "USER_CLEANUP"),
      Case(
        profile: "", command: "trap 'echo COMMAND_CLEANUP' EXIT; true", state: "done", status: 0,
        cleanup: "COMMAND_CLEANUP"),
      Case(
        profile: "", command: "trap 'echo COMMAND_CLEANUP' EXIT; exit 3", state: "error", status: 3,
        cleanup: "COMMAND_CLEANUP"),
    ]
    for item in cases {
      let home = try Home()
      defer { home.remove() }
      try Data((item.profile + "\n").utf8).write(to: home.root.appending(path: ".bash_profile"))
      let launch = RemoteLaunch(
        nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [],
        firstCommand: item.command)

      let (output, launcher) = try Self.launch(launch, shell: shell, home: home, input: "exit\n")

      let marker = Self.marker(launch.nonce, state: item.state, status: item.status)
      #expect(output.components(separatedBy: marker).count == 2, "\(item.command): \(output)")
      #expect(!output.contains("7501;state=\(item.state == "done" ? "error" : "done")"), "\(item.command): \(output)")
      #expect(output.contains(item.cleanup), "\(item.command): \(output)")
      #expect(!FileManager.default.fileExists(atPath: URL(filePath: launcher).deletingLastPathComponent().path))
    }
  }

  /// A subshell that fails under `set -e` while the command goes on is not the command's
  /// end: the launch reports once, after the whole command, with its own status.
  @Test func zshTakesNoSubshellFailureForTheCommands() throws {
    guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
    let home = try Home()
    defer { home.remove() }
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [],
      firstCommand: "(set -e; false)\necho RECOVERED\ntrue\n")

    let (output, _) = try Self.launch(launch, shell: "/bin/zsh", home: home, input: "exit\n")

    let marker = Self.marker(launch.nonce, state: "done", status: 0)
    #expect(output.components(separatedBy: "7501;").count == 2, "\(output)")
    let recovered = try #require(output.range(of: "RECOVERED"), "\(output)")
    let reported = try #require(output.range(of: marker), "\(output)")
    #expect(recovered.lowerBound < reported.lowerBound, "\(output)")
  }

  /// An interrupt (Ctrl-C) that stops the first command and gives the prompt back reports
  /// the command once, with status 130, before the shell ends; the shell's later exit status
  /// reports nothing more.
  @Test(arguments: shells)
  func anInterruptedFirstCommandReportsAtThePrompt(_ shell: String) throws {
    let home = try Home()
    defer { home.remove() }
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [],
      firstCommand: "echo FIRST_START; sleep 12; echo FIRST_END")
    let marker = Self.marker(launch.nonce, state: "error", status: 130)

    let (output, launcher) = try Self.launchInTerminal(
      launch, shell: shell, home: home,
      steps: [("FIRST_START", "\u{03}"), (marker, "echo AL\"\"IVE\nexit 4\n")])

    #expect(output.components(separatedBy: "7501;").count == 2, "\(output.debugDescription)")
    #expect(output.contains(marker), "\(output.debugDescription)")
    #expect(output.contains("ALIVE"), "\(output.debugDescription)")
    #expect(!output.contains("FIRST_END"), "\(output.debugDescription)")
    #expect(!FileManager.default.fileExists(atPath: URL(filePath: launcher).deletingLastPathComponent().path))
  }

  /// A first command that composes `PROMPT_COMMAND` (a `direnv hook bash` style prepend)
  /// still loses Prowl's hook, and the user's prompt hook sees the real exit status after.
  @Test(arguments: shells.filter { $0.hasSuffix("bash") })
  func bashRemovesItsPromptHookAfterAPrepend(_ shell: String) throws {
    let hook = #"_hook() { return $?; }; "#
    var cases = [
      (
        profile: #"PROMPT_COMMAND='printf "USER_STATUS:%s\n" "$?"'"#,
        command: hook + #"PROMPT_COMMAND="_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}""#
      )
    ]
    if shell.hasPrefix("/opt/homebrew") {
      cases.append(
        (
          profile: #"PROMPT_COMMAND=('printf "USER_STATUS:%s\n" "$?"')"#,
          command: hook + #"PROMPT_COMMAND=(_hook "${PROMPT_COMMAND[@]}")"#
        ))
    }
    for item in cases {
      let home = try Home()
      defer { home.remove() }
      try Data((item.profile + "\n").utf8).write(to: home.root.appending(path: ".bash_profile"))
      let launch = RemoteLaunch(
        nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [],
        firstCommand: item.command)

      let (output, _) = try Self.launch(
        launch, shell: shell, home: home, input: "false\necho \"PC:${PROMPT_COMMAND[*]}\"\nexit\n")

      #expect(output.contains(Self.marker(launch.nonce, state: "done", status: 0)), "\(item.command): \(output)")
      #expect(output.contains("USER_STATUS:1"), "\(item.command): \(output)")
      #expect(output.contains("PC:_hook"), "\(item.command): \(output)")
      #expect(!output.contains("prowl_interrupted"), "\(item.command): \(output)")
    }
  }

  /// A first command that never started, because the startup files ended or replaced the
  /// shell, did not run: no marker reports it, and the launch directory is gone.
  @Test func aFirstCommandThatNeverStartedReportsNothing() throws {
    // A shell, a startup file of that shell, and the file's text.
    let cases = [
      ["/bin/bash", ".bash_profile", "echo STARTUP; exit 0"],
      ["/bin/zsh", ".zlogin", "echo STARTUP; exec /bin/bash --noprofile --norc -i"],
    ].map { (shell: $0[0], file: $0[1], text: $0[2]) }
    for item in cases {
      let home = try Home()
      defer { home.remove() }
      try Data((item.text + "\n").utf8).write(to: home.root.appending(path: item.file))
      let launch = RemoteLaunch(
        nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [],
        firstCommand: "echo FIRST_COMMAND_RAN")

      let (output, launcher) = try Self.launch(launch, shell: item.shell, home: home, input: "exit 0\n")

      #expect(output.contains("STARTUP"), "\(item.shell): \(output)")
      #expect(!output.contains("FIRST_COMMAND_RAN"), "\(item.shell): \(output)")
      #expect(!output.contains("7501;"), "\(item.shell): \(output)")
      #expect(!FileManager.default.fileExists(atPath: URL(filePath: launcher).deletingLastPathComponent().path))
    }
  }

  /// A symlinked `~/.cache` keeps the launcher's logical path, which passes its check.
  @Test func aSymlinkedCacheDirectoryStillLaunches() throws {
    let home = try Home()
    defer { home.remove() }
    let elsewhere = home.root.appending(path: "elsewhere", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: home.root.appending(path: ".cache"), withDestinationURL: elsewhere)
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [], firstCommand: "true")

    let (output, _) = try Self.launch(launch, shell: "/bin/bash", home: home, input: "exit\n")

    #expect(output.contains(Self.marker(launch.nonce, state: "done", status: 0)), "\(output)")
  }

  /// A launcher outside its own launch directory removes nothing and starts nothing.
  @Test func aLauncherOutsideItsDirectoryRemovesNothing() throws {
    let home = try Home()
    defer { home.remove() }
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [], firstCommand: nil)
    let moved = home.root.appending(path: "work/launch.sh")
    try Data(RemoteLauncher.launcher(for: launch).utf8).write(to: moved)

    let output = try Self.run(
      "/bin/sh", [moved.path(percentEncoded: false)], input: "echo SHELL_STARTED\nexit\n",
      environment: ["HOME": home.path, "SHELL": "/bin/bash", "PATH": "/usr/bin:/bin"])

    #expect(output.contains("not in its launch directory"), "\(output)")
    #expect(!output.contains("SHELL_STARTED"))
    #expect(FileManager.default.fileExists(atPath: home.workingDirectory))
  }

  /// A failing first command reports its status; the shell stays.
  @Test(arguments: shells)
  func aFailingFirstCommandReportsItsStatus(_ shell: String) throws {
    let home = try Home()
    defer { home.remove() }
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [],
      firstCommand: shell.hasSuffix("fish") ? "false" : "(exit 3)")

    let (output, _) = try Self.launch(launch, shell: shell, home: home, input: "echo STILL_HERE\nexit\n")

    let status: Int32 = shell.hasSuffix("fish") ? 1 : 3
    #expect(output.contains(Self.marker(launch.nonce, state: "error", status: status)), "\(output)")
    #expect(output.contains("STILL_HERE"))
  }

  /// A plain shell starts in the working directory, reports nothing, and removes its files;
  /// a missing directory falls back to the home directory.
  @Test func aPlainShellStartsWithoutAMarker() throws {
    let home = try Home()
    defer { home.remove() }
    for directory in [home.workingDirectory, home.path + "/missing"] {
      let launch = RemoteLaunch(
        nonce: RemoteLaunch.makeNonce(), workingDirectory: directory, environment: [], firstCommand: nil)

      let (output, launcher) = try Self.launch(
        launch, shell: "/bin/bash", home: home, input: "echo \"AT:$PWD\"\nexit\n")

      let expected = directory.hasSuffix("missing") ? home.path : directory
      let physical = try #require(realpath(expected, nil))
      defer { free(physical) }
      #expect(
        output.contains("AT:\(expected)\n") || output.contains("AT:\(String(cString: physical))\n"), "\(output)")
      #expect(!output.contains("7501"))
      #expect(!FileManager.default.fileExists(atPath: URL(filePath: launcher).deletingLastPathComponent().path))
    }
  }

  /// Staging leaves no stale launches behind: a directory older than a day goes.
  @Test func stagingRemovesLaunchesThatNeverRan() throws {
    let home = try Home()
    defer { home.remove() }
    let base = home.root.appending(path: RemoteLauncher.launchDirectory)
    let stale = base.appending(path: "0000000000000000")
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: stale.path)
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: home.workingDirectory, environment: [], firstCommand: "true")

    let staging = try RemoteLauncher.stagingCommand(for: launch).script()
    let output = try Self.run(
      "/bin/sh", ["-s"], input: staging, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
    let launcher = try RemoteLauncher.stagedLauncherPath(from: output, for: launch)

    #expect(!FileManager.default.fileExists(atPath: stale.path))
    let attributes = try FileManager.default.attributesOfItem(
      atPath: URL(filePath: launcher).deletingLastPathComponent().path)
    #expect((attributes[.posixPermissions] as? Int) == 0o700)
  }

  // MARK: - Shells in a Linux container (opt-in)

  /// The image named by `PROWL_LAUNCHER_DOCKER_IMAGE` (`TEST_RUNNER_…` in xcodebuild), with
  /// fish, bash, zsh and dash, such as a Debian image with those packages.
  private static let dockerImage = ProcessInfo.processInfo.environment["PROWL_LAUNCHER_DOCKER_IMAGE"]

  /// Stages and runs a launch inside the container with `shell` as the login shell.
  /// With `interrupt`, the launcher runs in a terminal (`script`), gets the interrupt
  /// character after 3 s, then `echo ALIVE` and `exit 4`.
  private static func launchInDocker(
    _ launch: RemoteLaunch, shell: String, input: String, interrupt: Bool = false
  ) throws -> String {
    let image = try #require(dockerImage)
    let interruptedRun = """
      (sleep 3; printf '\\003'; sleep 2; printf 'echo AL""IVE\\nexit 4\\n'; sleep 2) |
        script -qc "sh $launcher" /dev/null 2>&1 || :
      """
    let staging = try RemoteLauncher.stagingCommand(for: launch).script()
    let driver = """
      set -e
      export HOME=/tmp/prowl-home SHELL=\(shell) TERM=dumb
      mkdir -p "$HOME/work/sub" "$HOME/.config/fish"
      echo 'echo zshrc >> "$HOME/startup.log"' > "$HOME/.zshrc"
      echo 'echo bash_profile >> "$HOME/startup.log"' > "$HOME/.bash_profile"
      echo 'echo fish_config >> $HOME/startup.log' > "$HOME/.config/fish/config.fish"
      sh -s > /tmp/staged <<'PROWL_STAGE'
      \(staging)PROWL_STAGE
      launcher=$(sed -n 's/^PROWL_LAUNCH\t//p' /tmp/staged)
      \(interrupt ? interruptedRun : "sh \"$launcher\" <<'PROWL_INPUT' 2>&1 || :\n\(input)PROWL_INPUT")
      echo "LOADS:$(tr '\n' ',' < "$HOME/startup.log" 2>/dev/null)"
      echo "LEFT:$(ls -A "$HOME/.cache/prowl/launch" | wc -l)"
      """
    let docker = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"].first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
    return try run(
      try #require(docker), ["run", "-i", "--rm", image, "sh", "-s"], input: driver,
      environment: ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": NSHomeDirectory()])
  }

  @Test(
    .enabled(if: dockerImage != nil),
    arguments: ["/usr/bin/fish", "/bin/bash", "/usr/bin/zsh", "/bin/dash"])
  func theLauncherWorksWithEachLinuxShell(_ shell: String) throws {
    let isFish = shell.hasSuffix("fish")
    let isDash = shell.hasSuffix("dash")
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: "/tmp/prowl-home/work", environment: [],
      firstCommand: isFish ? "cd sub; and set -gx PROWL_TEST yes" : "cd sub && PROWL_TEST=yes && export PROWL_TEST")
    let input =
      isFish
      ? "echo \"STATE:$PWD:$PROWL_TEST\"\nexit\n" : "echo \"STATE:$PWD:${PROWL_TEST-none}\"\nexit\n"

    let output = try Self.launchInDocker(launch, shell: shell, input: input)

    #expect(output.contains(Self.marker(launch.nonce, state: "done", status: 0)), "\(output)")
    #expect(output.contains("LEFT:0"), "\(output)")
    if isDash {
      // Another shell runs the command apart and then starts at the working directory.
      #expect(output.contains("STATE:/tmp/prowl-home/work:none"), "\(output)")
    } else {
      #expect(output.contains("STATE:/tmp/prowl-home/work/sub:yes"), "\(output)")
    }
    // A first command that ends the shell still reports.
    let exiting = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: "/tmp/prowl-home/work", environment: [], firstCommand: "exit 3"
    )
    let exited = try Self.launchInDocker(exiting, shell: shell, input: "echo SHOULD_NOT_RUN\n")
    #expect(exited.contains(Self.marker(exiting.nonce, state: "error", status: 3)), "\(exited)")
    // An interrupt reports the command once, with status 130.
    let long = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: "/tmp/prowl-home/work", environment: [],
      firstCommand: "echo FIRST_START; sleep 12; echo FIRST_END")
    let interrupted = try Self.launchInDocker(long, shell: shell, input: "", interrupt: true)
    #expect(interrupted.contains(Self.marker(long.nonce, state: "error", status: 130)), "\(interrupted)")
    #expect(interrupted.components(separatedBy: "7501;").count == 2, "\(interrupted)")
    #expect(interrupted.contains("ALIVE") && !interrupted.contains("FIRST_END"), "\(interrupted)")
    if isFish { #expect(output.contains("LOADS:fish_config,"), "\(output)") }
    if shell.hasSuffix("bash") { #expect(output.contains("LOADS:bash_profile,"), "\(output)") }
    if shell.hasSuffix("zsh") { #expect(output.contains("LOADS:zshrc,"), "\(output)") }
  }

  // MARK: - A real host (opt-in)

  /// Stages through the side channel of the host named by `PROWL_REMOTE_LANE_HOST`, then
  /// runs the launcher over a plain `ssh`, with the host user's own login shell.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PROWL_REMOTE_LANE_HOST"] != nil))
  func aRealHostRunsTheLauncherInTheUsersShell() async throws {
    let hostName = try #require(ProcessInfo.processInfo.environment["PROWL_REMOTE_LANE_HOST"])
    let owner = RemoteConnectionOwner(
      connection: ConnectionKey(user: NSUserName(), hostname: hostName),
      recipe: SSHConnectionRecipe(destination: hostName),
      configuration: RemoteConnectionOwner.Configuration(controlDirectory: "/tmp/prowl-lane-live"))
    let lane = RemoteCommandLane.owner(owner)
    let launch = RemoteLaunch(
      nonce: RemoteLaunch.makeNonce(), workingDirectory: "/tmp", environment: [],
      firstCommand: "cd / && PROWL_TEST=yes && export PROWL_TEST")
    guard case .exited(let staged) = try await lane.run(try RemoteLauncher.stagingCommand(for: launch), .commandLane)
    else {
      Issue.record("Staging did not run")
      return
    }
    let launcher = try RemoteLauncher.stagedLauncherPath(
      from: String(bytes: staged.output, encoding: .utf8) ?? "", for: launch)

    // The user's agent (`SSH_AUTH_SOCK`) authenticates the plain ssh, as in a pane.
    let output = try Self.run(
      "/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", hostName, "--", "exec", "sh", launcher],
      input: "echo \"STATE:$PWD:$PROWL_TEST\"\nexit\n",
      environment: ProcessInfo.processInfo.environment)

    #expect(output.contains(Self.marker(launch.nonce, state: "done", status: 0)), "\(output)")
    #expect(output.contains("STATE:/:yes"), "\(output)")
  }

  @Test func theMarkerIDAndTheNonceAreStrict() throws {
    let nonce = RemoteLaunch.makeNonce()
    #expect(RemoteLaunch.isValidNonce(nonce))
    #expect(!RemoteLaunch.isValidNonce("ABCDEF0123456789"))
    #expect(!RemoteLaunch.isValidNonce("abc"))
    #expect(
      RemoteLauncher.completion(fromMarkerID: "prowl-launch/\(nonce)/3")
        == RemoteLaunchCompletion(nonce: nonce, exitStatus: 3))
    #expect(RemoteLauncher.completion(fromMarkerID: "prowl-launch/\(nonce)") == nil)
    #expect(RemoteLauncher.completion(fromMarkerID: "other/\(nonce)/0") == nil)
    #expect(RemoteLauncher.completion(fromMarkerID: "prowl-launch/xyz/0") == nil)
    for status in ["+0", "-1", "256", "0x1", ""] {
      #expect(RemoteLauncher.completion(fromMarkerID: "prowl-launch/\(nonce)/\(status)") == nil, "\(status)")
    }
    #expect(throws: RemoteLauncher.StagingError.invalidLaunch) {
      try RemoteLauncher.stagingCommand(
        for: RemoteLaunch(
          nonce: nonce, workingDirectory: "/", environment: [RemoteLaunchVariable(name: "A;rm", value: "x")],
          firstCommand: nil))
    }
    #expect(throws: RemoteLauncher.StagingError.scriptTooLarge) {
      try RemoteLauncher.stagingCommand(
        for: RemoteLaunch(
          nonce: nonce, workingDirectory: "/", environment: [],
          firstCommand: String(repeating: "x", count: RemoteLauncher.maximumScriptBytes + 1)))
    }
    let other = RemoteLaunch(nonce: RemoteLaunch.makeNonce(), workingDirectory: "/", environment: [], firstCommand: nil)
    #expect(throws: RemoteLauncher.StagingError.unexpectedReply) {
      try RemoteLauncher.stagedLauncherPath(
        from: "PROWL_LAUNCH\t/home/u/.cache/prowl/launch/\(nonce)/launch.sh\n", for: other)
    }
    #expect(throws: RemoteLauncher.StagingError.invalidLaunch) {
      try RemoteLauncher.stagingCommand(
        for: RemoteLaunch(nonce: "bad", workingDirectory: "/", environment: [], firstCommand: nil))
    }
    #expect(throws: RemoteShellCommand.ValidationError.nulByte) {
      try RemoteLauncher.stagingCommand(
        for: RemoteLaunch(nonce: nonce, workingDirectory: "/", environment: [], firstCommand: "a\u{0}b")
      ).script()
    }
  }
}

nonisolated extension String {
  fileprivate var trimmingSuffixSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

/// Output that a reader thread collects.
private nonisolated final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()

  func append(_ chunk: Data) { lock.withLock { buffer.append(chunk) } }
  var data: Data { lock.withLock { buffer } }
}
