import Foundation
import Testing

@testable import supacode

struct GithubCLIOutputTests {
  private struct Payload: Decodable, Equatable {
    let name: String
  }

  // MARK: - balancedJSONSpans

  @Test func findsACleanObject() {
    let spans = GithubCLIOutput.balancedJSONSpans(in: #"{"name":"main"}"#)
    #expect(spans.map(String.init) == [#"{"name":"main"}"#])
  }

  @Test func skipsLeadingBannerBeforeObject() {
    let output = "nvm: version manager loaded\n{\"name\":\"main\"}"
    let spans = GithubCLIOutput.balancedJSONSpans(in: output)
    #expect(spans.map(String.init) == [#"{"name":"main"}"#])
  }

  @Test func skipsLeadingBannerBeforeArray() {
    let output = "Welcome!\n[{\"name\":\"main\"}]"
    let spans = GithubCLIOutput.balancedJSONSpans(in: output)
    #expect(spans.map(String.init) == [#"[{"name":"main"}]"#])
  }

  @Test func ignoresBracesAndEscapedQuotesInsideStrings() {
    let output = #"{"title":"a } b \" [c]"}"#
    let spans = GithubCLIOutput.balancedJSONSpans(in: output)
    #expect(spans.map(String.init) == [output])
  }

  @Test func returnsMultipleTopLevelValuesInOrder() {
    let output = #"{"name":"a"} trailing noise {"name":"b"}"#
    let spans = GithubCLIOutput.balancedJSONSpans(in: output)
    #expect(spans.map(String.init) == [#"{"name":"a"}"#, #"{"name":"b"}"#])
  }

  @Test func skipsStrayUnbalancedOpenerAndKeepsScanning() {
    // A verbose shell can emit a lone "{" that never balances; it must not
    // swallow the real payload that follows.
    let output = "{ partial banner\n{\"name\":\"main\"}"
    let spans = GithubCLIOutput.balancedJSONSpans(in: output)
    #expect(spans.map(String.init) == [#"{"name":"main"}"#])
  }

  @Test func yieldsNoSpansForNoiseEmptyOrUnterminated() {
    #expect(GithubCLIOutput.balancedJSONSpans(in: "").isEmpty)
    #expect(GithubCLIOutput.balancedJSONSpans(in: "just a banner, no json").isEmpty)
    #expect(GithubCLIOutput.balancedJSONSpans(in: #"{"name":"unterminated"#).isEmpty)
  }

  // MARK: - decode / decodeIfPresent

  @Test func decodesBannerPrefixedPayload() throws {
    let output = "Loading shell config...\n{\"name\":\"main\"}"
    let value = try GithubCLIOutput.decode(Payload.self, from: output)
    #expect(value == Payload(name: "main"))
  }

  @Test func prefersLastDecodableSpan() throws {
    // gh prints its JSON after any leading noise, so a leading banner-shaped
    // object must lose to the real trailing payload.
    let output = #"{"unrelated":"banner"} {"name":"real"}"#
    let value = try GithubCLIOutput.decode(Payload.self, from: output)
    #expect(value == Payload(name: "real"))
  }

  @Test func decodeIfPresentReturnsNilWhenNoPayload() throws {
    let value = try GithubCLIOutput.decodeIfPresent(Payload.self, from: "no json here")
    #expect(value == nil)
  }

  @Test func decodeThrowsNoPayloadMessageWhenMissing() {
    #expect(throws: GithubCLIError.commandFailed(GithubCLIOutput.noPayloadMessage)) {
      _ = try GithubCLIOutput.decode(Payload.self, from: "banner only")
    }
  }

  @Test func decodeThrowsUndecodableMessageForValidButWrongShapeJSON() {
    // Valid JSON whose shape doesn't match points at a gh version mismatch, not
    // shell pollution.
    #expect(throws: GithubCLIError.commandFailed(GithubCLIOutput.undecodableMessage)) {
      _ = try GithubCLIOutput.decode(Payload.self, from: #"{"unexpected":123}"#)
    }
  }

  // MARK: - activeAccount

  private func authResponse(_ json: String) throws -> GithubAuthStatusResponse {
    try GithubCLIOutput.decode(GithubAuthStatusResponse.self, from: json)
  }

  @Test func authStatusPreservesAllHostsAndAccounts() throws {
    let response = try authResponse(
      """
      {"hosts":{
        "github.com":[
          {"active":false,"login":"work","state":"success","gitProtocol":"ssh","tokenSource":"keyring"},
          {"active":true,"login":"personal","state":"success","gitProtocol":"ssh","tokenSource":"keyring"}
        ],
        "enterprise.internal":[
          {"active":true,"login":"enterprise","state":"success","gitProtocol":"https","tokenSource":"keyring"}
        ]
      }}
      """
    )

    let snapshot = GithubAuthStatusSnapshot(response: response)

    #expect(snapshot.hosts.count == 2)
    #expect(snapshot.accounts(on: "github.com").map(\.login) == ["work", "personal"])
    #expect(snapshot.activeAccount(on: "github.com")?.login == "personal")
    #expect(snapshot.activeAccount(on: "enterprise.internal")?.login == "enterprise")
  }

  @Test func picksActiveAccountFromNonFirstHost() throws {
    let response = try authResponse(
      #"{"hosts":{"git.example.com":[{"active":true,"login":"enterprise-user"}]}}"#
    )
    let active = GithubAuthStatusParsing.activeAccount(in: response)
    #expect(active?.host == "git.example.com")
    #expect(active?.login == "enterprise-user")
  }

  @Test func prefersGithubComWhenMultipleHostsActive() throws {
    let response = try authResponse(
      """
      {"hosts":{"git.example.com":[{"active":true,"login":"enterprise"}],\
      "github.com":[{"active":true,"login":"dotcom"}]}}
      """
    )
    let active = GithubAuthStatusParsing.activeAccount(in: response)
    #expect(active?.host == "github.com")
    #expect(active?.login == "dotcom")
  }

  @Test func sortsHostsDeterministicallyWhenGithubComAbsent() throws {
    let response = try authResponse(
      """
      {"hosts":{"zeta.example.com":[{"active":true,"login":"z"}],\
      "alpha.example.com":[{"active":true,"login":"a"}]}}
      """
    )
    let active = GithubAuthStatusParsing.activeAccount(in: response)
    #expect(active?.host == "alpha.example.com")
    #expect(active?.login == "a")
  }

  @Test func returnsNilWhenNoActiveAccount() throws {
    let response = try authResponse(
      #"{"hosts":{"github.com":[{"active":false,"login":"inactive"}]}}"#
    )
    #expect(GithubAuthStatusParsing.activeAccount(in: response) == nil)
  }
}
