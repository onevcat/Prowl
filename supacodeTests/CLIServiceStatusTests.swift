import Testing

@testable import supacode

struct CLIServiceStatusTests {
  @Test func listeningAndStoppedHaveNoFailure() {
    #expect(CLIServiceStatus.listening(path: "/tmp/cli.sock").failureDescription == nil)
    #expect(CLIServiceStatus.stopped.failureDescription == nil)
    #expect(CLIServiceStatus.listening(path: "/tmp/cli.sock").isListening)
    #expect(!CLIServiceStatus.stopped.isListening)
  }

  @Test func alreadyOwnedNamesTheCompetingInstanceAndTheOverride() throws {
    let description = try #require(
      CLIServiceStatus.failed(.socketAlreadyOwned, path: "/tmp/cli.sock").failureDescription)
    #expect(description.contains("Another Prowl"))
    #expect(description.contains("PROWL_CLI_SOCKET"))
  }

  @Test func everyFailureHasADescription() {
    let errors: [CLIServiceError] = [
      .socketCreationFailed, .socketPathTooLong, .socketAlreadyOwned, .lockFailed, .closeOnExecFailed,
      .permissionFailed, .bindFailed, .listenFailed, .readFailed, .writeFailed, .socketDirectoryUnavailable,
    ]
    for error in errors {
      #expect(CLIServiceStatus.failed(error, path: "/tmp/cli.sock").failureDescription?.isEmpty == false)
    }
  }
}
