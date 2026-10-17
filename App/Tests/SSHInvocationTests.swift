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
