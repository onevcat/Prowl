import Foundation
import Testing

@testable import Prowl

/// The supported grammar of a pane's local `ssh` command line (docs-ai 082, L0 item 2).
struct SSHInvocationTests {
  private func recipe(_ arguments: [String]) -> SSHConnectionRecipe? {
    guard case .supported(let recipe) = SSHInvocation.parse(arguments) else { return nil }
    return recipe
  }

  @Test func connectionOptionsAreReplayedAndTheRemoteCommandIsNot() {
    #expect(recipe(["mini"]) == SSHConnectionRecipe(destination: "mini"))
    #expect(
      recipe(["-p", "2222", "-l", "dev", "-i", "~/.ssh/id", "-J", "jump", "box", "claude", "--resume"])
        == SSHConnectionRecipe(
          destination: "box", options: ["-p", "2222", "-l", "dev", "-i", "~/.ssh/id", "-J", "jump"]))
    // Joined values and grouped flags.
    #expect(
      recipe(["-p2222", "-4C", "dev@box"])
        == SSHConnectionRecipe(destination: "dev@box", options: ["-p", "2222", "-4", "-C"]))
    #expect(recipe(["-F", "/tmp/cfg", "--", "box"])?.configFile == "/tmp/cfg")
  }

  @Test func optionsAfterTheDestinationShapeTheConnectionUntilTheCommand() {
    // OpenSSH keeps reading options after the destination.
    #expect(
      recipe(["host", "-p", "2222", "-l", "reviewer"])
        == SSHConnectionRecipe(destination: "host", options: ["-p", "2222", "-l", "reviewer"]))
    #expect(recipe(["host", "-o", "HostName=10.0.0.2"])?.options == ["-o", "HostName=10.0.0.2"])
    // The first other argument starts the command; what follows is the command's.
    #expect(
      recipe(["-p", "22", "host", "claude", "-p", "prompt"])
        == SSHConnectionRecipe(destination: "host", options: ["-p", "22"]))
    #expect(recipe(["host", "--", "-p", "2222"])?.options == [])
  }

  @Test func relativeOperandsKeepTheSSHWorkingDirectory() {
    guard
      case .supported(let parsed) = SSHInvocation.parse(["-F", "./ssh_config", "dev"], workingDirectory: "/work/proj")
    else {
      Issue.record("expected supported")
      return
    }
    #expect(parsed.workingDirectory == "/work/proj")
    #expect(parsed.configFile == "/work/proj/ssh_config")
    #expect(
      SSHConnectionRecipe(destination: "d", options: ["-F", "~/cfg"], workingDirectory: "/w").configFile == "~/cfg")
  }

  @Test func forwardingSessionAndControlOptionsAreDropped() {
    let parsed = recipe([
      "-t", "-A", "-X", "-v", "-L", "8080:localhost:80", "-R", "9000:localhost:9000", "-D", "1080", "-S", "/tmp/ctl",
      "-o", "LocalForward=1 localhost:1", "-o", "RemoteCommand=tmux attach", "-o", "RequestTTY yes", "-o",
      "ControlMaster=auto", "-o", "ConnectTimeout=3", "-o", "SendEnv=FOO", "box",
    ])
    #expect(parsed == SSHConnectionRecipe(destination: "box"))
  }

  @Test func connectionShapingConfigOptionsAreReplayedInAnySpelling() {
    #expect(
      recipe(["-o", "Port=2222", "-o", "IdentityFile ~/.ssh/k", "-oUser=dev", "-o", "ProxyJump = j", "box"])?.options
        == ["-o", "Port=2222", "-o", "IdentityFile ~/.ssh/k", "-o", "User=dev", "-o", "ProxyJump = j"])
  }

  @Test(arguments: [
    ["-N", "box"], ["-f", "box"], ["-W", "host:22", "jump"], ["-G", "box"], ["-O", "check", "box"],
    ["-s", "box", "sftp"], ["-Z", "box"], ["-o", "FancyNewOption=yes", "box"], ["-p"], [], ["-v"],
  ])
  func anythingOutsideTheGrammarIsUnsupported(arguments: [String]) {
    guard case .unsupported = SSHInvocation.parse(arguments) else {
      Issue.record("expected unsupported for \(arguments)")
      return
    }
  }
}
