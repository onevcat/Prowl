import Foundation

/// A terminal launch in a remote folder (docs-ai 084 C3, D5, D5a). Prowl stages a launcher
/// on the host over the side channel, then types one line into a local pane:
/// `ssh -t <recipe> -- exec sh <launcher>`. The launcher sets the working directory and the
/// worktree environment, then hands over to the user's interactive login shell. A setup,
/// run or custom script runs as that shell's first command, so state such as a `cd` stays
/// at the prompt, and its exit status comes back as a marker with this launch's nonce.
nonisolated struct RemoteLaunch: Equatable, Sendable {
  /// 16 lowercase hex digits; names the launch directory and the completion marker.
  let nonce: String
  /// The path on the host where the shell starts.
  let workingDirectory: String
  /// Exported before the shell starts, in order.
  let environment: [RemoteLaunchVariable]
  /// The script that the user's shell runs as its first command; nil for a plain shell.
  let firstCommand: String?

  static func makeNonce() -> String {
    (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
  }

  static func isValidNonce(_ nonce: String) -> Bool {
    nonce.utf8.count == 16 && nonce.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

nonisolated struct RemoteLaunchVariable: Equatable, Sendable {
  let name: String
  let value: String
}

/// What a remote launch's first command reported (`RemoteLauncher.marker`).
nonisolated struct RemoteLaunchCompletion: Equatable, Sendable {
  let nonce: String
  let exitStatus: Int32
}

nonisolated enum RemoteLauncher {
  enum StagingError: Error, Equatable, LocalizedError {
    case invalidLaunch
    case scriptTooLarge
    case unexpectedReply

    var errorDescription: String? {
      switch self {
      case .invalidLaunch: String(localized: "Prowl could not prepare the terminal for the remote folder.")
      case .scriptTooLarge: String(localized: "The script is too large to run in a remote folder.")
      case .unexpectedReply: String(localized: "The remote host did not confirm the terminal launch.")
      }
    }
  }

  /// The largest launcher or first command, in bytes. Each travels as one argument, and
  /// Linux allows 128 KiB per argument (`MAX_ARG_STRLEN`).
  static let maximumScriptBytes = 100_000

  /// The launch directories under the user's home on the host; each launch has its own.
  static let launchDirectory = ".cache/prowl/launch"
  /// The id prefix of the completion marker (OSC 7501, `id=prowl-launch/<nonce>/<status>`).
  static let markerIDPrefix = "prowl-launch"

  // MARK: - Staging

  /// Writes the launcher and the first command into a new launch directory (mode 0700) on
  /// the host, removes launch directories older than a day that ssh never ran, and prints
  /// the launcher's absolute path. It runs through `sh -s` (`RemoteCommandLane.run`), so the
  /// host needs no bash.
  static func stagingCommand(for launch: RemoteLaunch) throws(StagingError) -> RemoteShellCommand {
    guard RemoteLaunch.isValidNonce(launch.nonce),
      launch.environment.allSatisfy({ RemoteShellCommand.isValidName($0.name) })
    else { throw .invalidLaunch }
    let launcher = launcher(for: launch)
    guard launcher.utf8.count <= maximumScriptBytes, (launch.firstCommand?.utf8.count ?? 0) <= maximumScriptBytes
    else { throw .scriptTooLarge }
    let script = """
      set -e
      umask 077
      prowl_base="$HOME/\(launchDirectory)"
      mkdir -p "$prowl_base"
      find "$prowl_base" -mindepth 1 -maxdepth 1 -type d -mtime +0 -exec rm -rf {} + 2>/dev/null || :
      prowl_dir="$prowl_base/$1"
      mkdir "$prowl_dir"
      printf '%s' "$2" > "$prowl_dir/launch.sh"
      if [ "$3" = 1 ]; then printf '%s' "$4" > "$prowl_dir/command"; fi
      printf 'PROWL_LAUNCH\\t%s\\n' "$prowl_dir/launch.sh"
      """
    return RemoteShellCommand(
      executable: "sh",
      arguments: [
        "-c", script, "sh", launch.nonce, launcher,
        launch.firstCommand == nil ? "0" : "1", launch.firstCommand ?? "",
      ])
  }

  /// The launcher's path from the staging command's output: only this launch's own path,
  /// so login output or another line never names the script that a pane runs.
  static func stagedLauncherPath(from output: String, for launch: RemoteLaunch) throws(StagingError) -> String {
    let suffix = "/\(launchDirectory)/\(launch.nonce)/launch.sh"
    for line in output.split(separator: "\n").reversed() {
      let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
      if fields.count == 2, fields[0] == "PROWL_LAUNCH", fields[1].hasPrefix("/"), fields[1].hasSuffix(suffix) {
        return fields[1]
      }
    }
    throw .unexpectedReply
  }

  // MARK: - Launcher

  /// The POSIX `sh` launcher. The user's startup files load exactly once, and each wrapper
  /// clears its injection variables before the first command, so a nested shell never
  /// replays it:
  /// - zsh: `ZDOTDIR` points at a wrapper whose `.zshenv` restores the user's `ZDOTDIR`, so
  ///   zsh reads the user's files, and adds a one-time `precmd` hook for the first command;
  /// - bash: an interactive non-login shell (`--noprofile --rcfile`) whose rc file replays
  ///   the login files; `shopt login_shell` is off and `~/.bash_logout` does not run;
  /// - fish: `--init-command`, which runs after the user's configuration;
  /// - any other shell runs the command with `-c`, then `exec`s a login shell, without the
  ///   persistent state. Not `-i`: an interactive dash drops into a prompt after an interrupt.
  ///
  /// Each wrapper marks the first command as started (a `started` file), then reports it
  /// when it finishes, or with status 130 when an interrupt (Ctrl-C) stops it and the prompt
  /// comes back. No trap of the user's is replaced, so a subshell's failure is not taken for
  /// the command's. The launcher waits for the shell instead of `exec`ing it: when the shell
  /// ends in the command (`exit`, `errexit`), the launcher reports the shell's exit status.
  /// A command that never started (startup files that replace the shell) sends no marker.
  static func launcher(for launch: RemoteLaunch) -> String {
    let quote = RemoteShellCommand.quote
    let exports = launch.environment.map { "\($0.name)=\(quote($0.value)); export \($0.name)" }
    let marker = { (shellPrintf: String) in shellPrintf.replacing("NONCE", with: launch.nonce) }
    return """
      # Prowl remote terminal (docs-ai 084 C3). It removes itself.
      # Only its own launch directory is ever removed: the path that staging printed, as
      # typed (a symlinked ~/.cache keeps its logical path).
      prowl_dir=$(dirname -- "$0")
      case $prowl_dir in
        /*/\(launchDirectory)/\(launch.nonce)) ;;
        *) echo "prowl: the launcher is not in its launch directory" >&2; exit 1 ;;
      esac
      cd -- \(quote(launch.workingDirectory)) 2>/dev/null || cd || :
      \(exports.joined(separator: "\n"))
      prowl_shell=${SHELL-}
      if [ -z "$prowl_shell" ] || [ ! -x "$prowl_shell" ]; then
        prowl_shell=$(command -v zsh || command -v bash || echo /bin/sh)
      fi
      if [ ! -f "$prowl_dir/command" ]; then
        rm -rf -- "$prowl_dir"
        exec "$prowl_shell" -l
      fi
      PROWL_LAUNCH_DIR=$prowl_dir; export PROWL_LAUNCH_DIR
      case ${prowl_shell##*/} in
        zsh)
          mkdir -- "$prowl_dir/zsh"
          cat > "$prowl_dir/zsh/.zshenv" <<'PROWL_EOF'
      \(zshEnvironment)
      PROWL_EOF
          cat > "$prowl_dir/zsh/.zprofile" <<'PROWL_EOF'
      \(zshUserFile(".zprofile"))
      PROWL_EOF
          cat > "$prowl_dir/zsh/.zshrc" <<'PROWL_EOF'
      \(zshUserFile(".zshrc"))
      PROWL_EOF
          cat > "$prowl_dir/zsh/.zlogin" <<'PROWL_EOF'
      \(zshLogin(marker: marker(posixMarker)))
      PROWL_EOF
          if [ "${ZDOTDIR+set}" = set ]; then
            PROWL_USER_ZDOTDIR=$ZDOTDIR; PROWL_USER_ZDOTDIR_SET=1
            export PROWL_USER_ZDOTDIR PROWL_USER_ZDOTDIR_SET
          fi
          ZDOTDIR=$prowl_dir/zsh; export ZDOTDIR
          "$prowl_shell" -i -l
          ;;
        bash)
          cat > "$prowl_dir/bashrc" <<'PROWL_EOF'
      \(bashRC(marker: marker(posixMarker)))
      PROWL_EOF
          "$prowl_shell" --noprofile --rcfile "$prowl_dir/bashrc" -i
          ;;
        fish)
          cat > "$prowl_dir/init.fish" <<'PROWL_EOF'
      \(fishInit(marker: marker(fishMarker)))
      PROWL_EOF
          "$prowl_shell" -i -l --init-command 'source $PROWL_LAUNCH_DIR/init.fish'
          ;;
        *)
          unset PROWL_LAUNCH_DIR
          # The command shares the launcher's process group: a caught (not ignored) signal
          # keeps the launcher alive for the report, and the command still gets the default.
          trap : INT QUIT
          "$prowl_shell" -c "$(cat "$prowl_dir/command")"
          prowl_status=$?
          trap - INT QUIT
          rm -rf -- "$prowl_dir"
          if [ "$prowl_status" = 0 ]; then prowl_state=done; else prowl_state=error; fi
          \(marker(posixMarker))
          exec "$prowl_shell" -l
          ;;
      esac
      # The shell ended. Its directory is still here when the first command did not report:
      # an `exit` or an `errexit` failure in a started command reports the shell's exit
      # status. A command that never started (startup files that replaced the shell) did
      # not run, so nothing reports.
      prowl_status=$?
      if [ -f "$prowl_dir/started" ]; then
        if [ "$prowl_status" = 0 ]; then prowl_state=done; else prowl_state=error; fi
        rm -rf -- "$prowl_dir"
        \(marker(posixMarker))
      elif [ -d "$prowl_dir" ]; then
        rm -rf -- "$prowl_dir"
      fi
      exit "$prowl_status"

      """
  }

  /// `printf` of the marker for `sh`, bash and zsh, with `$prowl_state` and `$prowl_status`.
  private static let posixMarker =
    #"printf '\033]7501;state=%s:id=\#(markerIDPrefix)/NONCE/%s\007' "$prowl_state" "$prowl_status""#
  private static let fishMarker =
    #"printf '\e]7501;state=%s:id=\#(markerIDPrefix)/NONCE/%s\a' $prowl_state $prowl_status"#

  /// The wrapper's `.zshenv`. Each wrapper file runs the user's own file at top level (a
  /// function would make its `typeset` declarations local) with the user's `ZDOTDIR` in
  /// place, then points zsh back at the wrapper for the next file. A user `.zshenv` that
  /// sets `ZDOTDIR` (the XDG layout) moves the user's directory with it.
  private static let zshEnvironment = """
    # Prowl remote terminal (docs-ai 084 C3): the user's files, each from the user's ZDOTDIR.
    prowl_wrapper_dir=$ZDOTDIR
    prowl_launch_dir=$PROWL_LAUNCH_DIR
    unset prowl_user_zdotdir
    [ -n "${PROWL_USER_ZDOTDIR_SET-}" ] && prowl_user_zdotdir=$PROWL_USER_ZDOTDIR
    unset PROWL_LAUNCH_DIR PROWL_USER_ZDOTDIR PROWL_USER_ZDOTDIR_SET
    \(zshUserFile(".zshenv"))
    """

  /// Runs the user's `file` (such as `.zshrc`) at top level, from the user's `ZDOTDIR`, and
  /// keeps a `ZDOTDIR` that it changes.
  private static func zshUserFile(_ file: String) -> String {
    """
    if [ -n "${prowl_user_zdotdir+set}" ]; then ZDOTDIR=$prowl_user_zdotdir; else unset ZDOTDIR; fi
    [ -f "${ZDOTDIR:-$HOME}/\(file)" ] && source "${ZDOTDIR:-$HOME}/\(file)"
    if [ -n "${ZDOTDIR+set}" ]; then prowl_user_zdotdir=$ZDOTDIR; else unset prowl_user_zdotdir; fi
    ZDOTDIR=$prowl_wrapper_dir
    """
  }

  /// The wrapper's `.zlogin`, the last startup file of a login shell: the user's `ZDOTDIR`
  /// comes back for good, and the first command runs from a `precmd` hook added after the
  /// user's own hooks, such as an instant prompt that captures output until its hook ran.
  /// An `always` block reports an interrupt, which ends the hook and shows the prompt. zsh
  /// also runs that block for an `exit`, with no usable status, so it reports nothing else.
  private static func zshLogin(marker: String) -> String {
    """
    \(zshUserFile(".zlogin"))
    if [ -n "${prowl_user_zdotdir+set}" ]; then ZDOTDIR=$prowl_user_zdotdir; else unset ZDOTDIR; fi
    unset prowl_user_zdotdir prowl_wrapper_dir
    prowl_report() {
      [ -n "${prowl_launch_dir-}" ] || return 0
      local prowl_status=$1 prowl_state=error
      [ "$prowl_status" = 0 ] && prowl_state=done
      rm -rf -- "$prowl_launch_dir"
      unset prowl_launch_dir
      \(marker)
    }
    prowl_first_command() {
      precmd_functions=(${precmd_functions:#prowl_first_command})
      : > "$prowl_launch_dir/started"
      {
        source "$prowl_launch_dir/command"
      } always {
        (( TRY_BLOCK_INTERRUPT )) && prowl_report 130
      }
      prowl_report $?
      unfunction prowl_first_command prowl_report
    }
    precmd_functions+=(prowl_first_command)
    """
  }

  /// The bash rc file: the login files, then the first command. An interrupt stops the rc
  /// file and shows the prompt, so a `PROMPT_COMMAND` hook, added before the command and
  /// removed after it, reports it with 130 (bash 3.2 gives 128 or 130 for the same Ctrl-C).
  /// A command that composes `PROMPT_COMMAND` (`direnv hook bash` puts its hook first) can
  /// move the hook, also into an array element; the removal looks in every element. A hook
  /// that stays keeps the incoming exit status and does nothing after the launch.
  private static func bashRC(marker: String) -> String {
    """
    # Prowl remote terminal (docs-ai 084 C3): the login files, then the first command.
    prowl_launch_dir=$PROWL_LAUNCH_DIR
    unset PROWL_LAUNCH_DIR
    [ -r /etc/profile ] && . /etc/profile
    for prowl_file in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      if [ -r "$prowl_file" ]; then . "$prowl_file"; break; fi
    done
    unset prowl_file
    prowl_report() {
      [ -n "${prowl_launch_dir-}" ] || return 0
      local prowl_status=$1 prowl_state=error
      [ "$prowl_status" = 0 ] && prowl_state=done
      rm -rf -- "$prowl_launch_dir"
      unset prowl_launch_dir
      \(marker)
    }
    prowl_unhook() {
      local prowl_i prowl_hook
      for prowl_i in "${!PROMPT_COMMAND[@]}"; do
        prowl_hook=${PROMPT_COMMAND[prowl_i]}
        prowl_hook=${prowl_hook//prowl_interrupted; /}
        prowl_hook=${prowl_hook//prowl_interrupted;/}
        prowl_hook=${prowl_hook%;prowl_interrupted}
        [ "$prowl_hook" = prowl_interrupted ] && prowl_hook=
        if [ "$prowl_hook" != "${PROMPT_COMMAND[prowl_i]}" ]; then
          if [ "$prowl_i" = 0 ]; then PROMPT_COMMAND=$prowl_hook; else PROMPT_COMMAND[prowl_i]=$prowl_hook; fi
        fi
      done
    }
    prowl_interrupted() {
      local prowl_status=$?
      prowl_unhook
      [ -n "${prowl_launch_dir-}" ] && prowl_report 130
      return $prowl_status
    }
    PROMPT_COMMAND="prowl_interrupted${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
    : > "$prowl_launch_dir/started"
    . "$prowl_launch_dir/command"
    prowl_report $?
    prowl_unhook
    """
  }

  /// The fish init command: the first command after the configuration. An interrupt stops
  /// the init command and shows the prompt, so a one-time `fish_prompt` handler reports it.
  private static func fishInit(marker: String) -> String {
    """
    # Prowl remote terminal (docs-ai 084 C3): the first command, after the configuration.
    set -g prowl_launch_dir $PROWL_LAUNCH_DIR
    set -e PROWL_LAUNCH_DIR
    function prowl_report --argument-names prowl_status
      set -q prowl_launch_dir; or return 0
      rm -rf -- $prowl_launch_dir
      set -e prowl_launch_dir
      set -l prowl_state error
      test $prowl_status -eq 0; and set prowl_state done
      \(marker)
    end
    function prowl_interrupted --on-event fish_prompt
      functions -e prowl_interrupted
      prowl_report 130
    end
    touch $prowl_launch_dir/started
    source $prowl_launch_dir/command
    prowl_report $status
    functions -e prowl_interrupted
    """
  }

  // MARK: - Marker

  /// The completion of a launch from an OSC 7501 report id, `prowl-launch/<nonce>/<status>`.
  static func completion(fromMarkerID id: String) -> RemoteLaunchCompletion? {
    let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, parts[0] == markerIDPrefix, RemoteLaunch.isValidNonce(parts[1]),
      (1...3).contains(parts[2].utf8.count), parts[2].utf8.allSatisfy({ (48...57).contains($0) }),
      let status = Int32(parts[2]), (0...255).contains(status)
    else { return nil }
    return RemoteLaunchCompletion(nonce: parts[1], exitStatus: status)
  }
}
