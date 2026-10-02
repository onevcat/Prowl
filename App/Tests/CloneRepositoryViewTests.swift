import Foundation
import Testing

@testable import supacode

struct CloneRepositoryViewTests {
  @Test func cloneRequestTrimsURLAndNormalizesDestinationPath() {
    let request = CloneRepositoryView.cloneRequest(
      urlString: " https://github.com/onevcat/Prowl.git \n",
      locationPath: " ~/Developer "
    )

    let expectedPath = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Developer", directoryHint: .isDirectory)
      .appending(path: "Prowl", directoryHint: .isDirectory)
      .standardizedFileURL
      .path(percentEncoded: false)

    #expect(request?.url == "https://github.com/onevcat/Prowl.git")
    #expect(request?.destination.path(percentEncoded: false) == expectedPath)
  }

  @Test func extractRepoNameHandlesCommonGitURLForms() {
    #expect(CloneRepositoryView.extractRepoName(from: "git@github.com:onevcat/Prowl.git") == "Prowl")
    #expect(CloneRepositoryView.extractRepoName(from: "git@github.com:Prowl.git") == "Prowl")
    #expect(CloneRepositoryView.extractRepoName(from: "https://github.com/onevcat/Prowl.git?ref=main") == "Prowl")
    #expect(CloneRepositoryView.extractRepoName(from: " https://github.com/onevcat/Prowl.git/ ") == "Prowl")
  }

  @Test func isGitURLTrimsClipboardContentAndRequiresKnownHostsForHTTPURLs() {
    #expect(CloneRepositoryView.isGitURL(" https://github.com/onevcat/Prowl \n"))
    #expect(CloneRepositoryView.isGitURL("git@github.com:onevcat/Prowl.git"))
    #expect(CloneRepositoryView.isGitURL("ssh://git@example.com/onevcat/Prowl.git"))
    #expect(!CloneRepositoryView.isGitURL("https://github.com.evil/onevcat/Prowl"))
  }
}
